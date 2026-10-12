package com.pestana.estudio.practice

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import com.pestana.estudio.MainActivity
import com.pestana.estudio.R
import com.pestana.estudio.audio.AudioDecoder
import com.pestana.estudio.audio.PcmFile
import org.json.JSONObject
import java.io.File
import kotlin.concurrent.thread

/**
 * Separação de instrumentos num PROCESSO SEPARADO (":ia"), como serviço em primeiro plano:
 * - a IA tem a própria cota de memória; se o Android matar o processo por falta de memória,
 *   o app continua aberto e explica o que houve (em vez de fechar tudo);
 * - continua rodando com a tela apagada ou com o app em segundo plano.
 * O progresso vai para um arquivo de status que a tela lê (funciona entre processos).
 */
class SeparationService : Service() {
    companion object {
        const val EXTRA_SONG = "song"
        const val ACTION_CANCEL = "com.pestana.estudio.CANCEL_SEPARATION"
        private const val CHANNEL = "separacao"
        private const val NOTIFICATION_ID = 42

        fun statusFile(ctx: Context) = File(File(ctx.filesDir, "practice"), "separation-status.json")

        fun start(ctx: Context, songId: String) {
            statusFile(ctx).apply { parentFile?.mkdirs() }.writeText(
                JSONObject().put("state", "starting").put("songId", songId).put("progress", 0.0)
                    .put("time", System.currentTimeMillis()).toString(),
            )
            val i = Intent(ctx, SeparationService::class.java).putExtra(EXTRA_SONG, songId)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }

        fun cancel(ctx: Context) {
            ctx.startService(Intent(ctx, SeparationService::class.java).setAction(ACTION_CANCEL))
        }

        /** Threads da IA conforme a memória do aparelho (menos threads = menor pico de memória). */
        fun threadsFor(ctx: Context): Int {
            val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val mi = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
            val gb = mi.totalMem / (1024.0 * 1024 * 1024)
            val cores = Runtime.getRuntime().availableProcessors()
            return when {
                gb < 4.5 || am.isLowRamDevice -> 2
                gb < 7 -> minOf(3, cores)
                else -> minOf(4, cores)
            }.coerceAtLeast(1)
        }
    }

    @Volatile private var cancelled = false
    @Volatile private var running = false
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            cancelled = true
            if (!running) stopSelf()
            return START_NOT_STICKY
        }
        val songId = intent?.getStringExtra(EXTRA_SONG) ?: run { stopSelf(); return START_NOT_STICKY }
        goForeground(0)
        if (running) return START_NOT_STICKY
        running = true
        cancelled = false
        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "pestana:separacao").apply { acquire(3 * 60 * 60 * 1000L) }
        thread(name = "pestana-ia") { work(songId) }
        return START_NOT_STICKY
    }

    private fun write(state: String, songId: String, progress: Double, stage: String = "", extra: JSONObject.() -> Unit = {}) {
        val o = JSONObject().put("state", state).put("songId", songId).put("progress", progress).put("stage", stage)
            .put("time", System.currentTimeMillis())
        o.extra()
        val f = statusFile(this)
        val tmp = File(f.parentFile, f.name + ".tmp")
        tmp.writeText(o.toString())
        tmp.renameTo(f)
    }

    private fun work(songId: String) {
        val store = PracticeLibrary(filesDir, cacheDir)
        val song = store.load().firstOrNull { it.id == songId }
        try {
            if (song == null) throw IllegalStateException("música não encontrada")
            write("running", songId, 0.0, "Preparando a música…")
            val songPcm = store.songPcm(song)
            if (!songPcm.exists()) AudioDecoder.decodeToPcm(this, Uri.fromFile(store.songFile(song)), songPcm, cancelled = { cancelled })
            write("running", songId, 0.0, "Separando os instrumentos…")
            var last = -1
            val result = PcmFile(songPcm).use { pcm ->
                DemucsOnnxSeparator(ModelStore(filesDir).file, threadsFor(this)).separate(
                    pcm,
                    pcmCacheFor = { kind -> store.stemPcm(song, kind) },
                    m4aFor = { kind -> File(store.stemsFolder(song), "${kind.key}.m4a") },
                    progress = { p ->
                        val pct = (p * 100).toInt()
                        write("running", songId, p, if (p < 0.9) "Separando os instrumentos…" else "Guardando os instrumentos…")
                        if (pct != last) { last = pct; goForeground(pct) }
                    },
                    cancelled = { cancelled },
                )
            }
            val stems = JSONObject()
            result.stems.forEach { (k, f) -> stems.put(k.key, f.name) }
            write("done", songId, 1.0) { put("stems", stems) }
        } catch (e: InterruptedException) {
            write("cancelled", songId, 0.0)
        } catch (e: OutOfMemoryError) {
            write("error", songId, 0.0) { put("message", "Faltou memória para a separação neste aparelho.") }
        } catch (e: Throwable) {
            write("error", songId, 0.0) { put("message", "A separação falhou: ${e.message ?: e.javaClass.simpleName}") }
        } finally {
            running = false
            wakeLock?.let { if (it.isHeld) it.release() }
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun goForeground(pct: Int) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Separação de instrumentos", NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val n: Notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Separando os instrumentos")
            .setContentText(if (pct > 0) "$pct% — a IA roda no próprio celular" else "Preparando…")
            .setProgress(100, pct, pct == 0)
            .setOngoing(true)
            .setContentIntent(open)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }
}
