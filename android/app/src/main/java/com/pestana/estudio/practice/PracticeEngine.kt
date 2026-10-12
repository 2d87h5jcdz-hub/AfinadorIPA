package com.pestana.estudio.practice

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.pestana.estudio.audio.AudioDecoder
import com.pestana.estudio.audio.AudioOutput
import com.pestana.estudio.audio.AudioTrackOutput
import com.pestana.estudio.audio.PcmFile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID
import kotlin.math.roundToInt

data class StemMix(val volume: Float = 1f, val muted: Boolean = false, val solo: Boolean = false)

/** Treino: biblioteca, player com tom/velocidade/loop A-B e separação por IA (portado do iOS). */
class PracticeEngine(context: Context) {
    companion object {
        val SEMITONES = -6..6
        const val SPEED_MIN = 0.5
        const val SPEED_MAX = 1.25
        const val MIN_LOOP = 0.5
        private const val SR = PcmFile.SAMPLE_RATE.toDouble()
    }

    private val app = context.applicationContext
    private val store = PracticeLibrary(app.filesDir, app.cacheDir)
    val models = ModelStore(app.filesDir)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // Biblioteca
    var library by mutableStateOf(store.load().sortedByDescending { it.addedAt })
        private set
    var current by mutableStateOf<PracticeSong?>(null)
        private set

    // Estado de trabalho em segundo plano
    var busy by mutableStateOf<String?>(null) // "Importando…", "Preparando…"
        private set
    var lastError by mutableStateOf<String?>(null)

    // Transporte
    var isPlaying by mutableStateOf(false)
        private set
    var position by mutableDoubleStateOf(0.0)
        private set
    var duration by mutableDoubleStateOf(0.0)
        private set
    var semitones by mutableIntStateOf(0)
        private set
    var speed by mutableDoubleStateOf(1.0)
        private set
    var loopA by mutableStateOf<Double?>(null)
        private set
    var loopB by mutableStateOf<Double?>(null)
        private set
    val loopActive get() = loopA != null && loopB != null

    // Stems
    var useStems by mutableStateOf(false)
        private set
    val stemMix = mutableStateMapOf<StemKind, StemMix>()
    val availableStems: List<StemKind>
        get() = current?.let { s -> StemKind.entries.filter { s.stemFiles.containsKey(it.key) } } ?: emptyList()

    // Separação
    var separating by mutableStateOf(false)
        private set
    var separationStage by mutableStateOf("")
        private set
    var separationProgress by mutableDoubleStateOf(0.0)
        private set
    private var separationJob: Job? = null

    init {
        // Separação que continuou rodando (serviço da IA) enquanto o app estava fechado.
        scope.launch { resumeSeparationIfRunning() }
    }
    @Volatile private var cancelFlag = false

    // Áudio
    private val renderer = PracticeRenderer()
    private val output: AudioOutput =
        AudioTrackOutput(PcmFile.SAMPLE_RATE, renderer, stopWhenIdle = false, channels = 2, lowLatency = false)
    private var pcms: List<Pair<StemKind?, PcmFile>> = emptyList()
    private var tracks: List<PracticeRenderer.Track> = emptyList()
    private var ticker: Job? = null

    // MARK: biblioteca

    private fun saveLibrary() = store.save(library)

    private fun update(song: PracticeSong) {
        library = library.map { if (it.id == song.id) song else it }
        if (current?.id == song.id) current = song
        saveLibrary()
    }

    fun importSong(uri: Uri) {
        if (busy != null) return
        busy = "Importando…"
        scope.launch {
            try {
                val song = withContext(Dispatchers.IO) { copyIntoLibrary(uri) }
                library = listOf(song) + library
                saveLibrary()
                open(song)
            } catch (e: Exception) {
                lastError = "Não consegui importar: ${e.message ?: e.javaClass.simpleName}"
            } finally {
                if (busy == "Importando…") busy = null
            }
        }
    }

    private fun displayName(uri: Uri): String? = try {
        app.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    } catch (_: Exception) {
        null
    }

    private fun copyIntoLibrary(uri: Uri): PracticeSong {
        val name = displayName(uri) ?: uri.lastPathSegment?.substringAfterLast('/') ?: "Música"
        val ext = name.substringAfterLast('.', "").lowercase().takeIf { it.length in 2..5 } ?: "m4a"
        val title = name.substringBeforeLast('.').ifBlank { "Música" }
        val id = UUID.randomUUID().toString()
        val draft = PracticeSong(id = id, title = title, fileName = "song.$ext", duration = 0.0)
        val folder = store.folder(draft).also { it.mkdirs() }
        try {
            val dest = store.songFile(draft)
            app.contentResolver.openInputStream(uri)?.use { input -> dest.outputStream().use { input.copyTo(it) } }
                ?: throw java.io.IOException("arquivo inacessível")
            // Decodifica já: valida o arquivo e deixa o PCM pronto para tocar.
            val frames = AudioDecoder.decodeToPcm(app, Uri.fromFile(dest), store.songPcm(draft))
            val seconds = frames / SR
            if (seconds < 0.5) throw java.io.IOException("o arquivo é curto demais ou não tem áudio")
            return draft.copy(duration = seconds)
        } catch (e: Exception) {
            folder.deleteRecursively()
            store.cacheFolder(draft).deleteRecursively()
            throw e
        }
    }

    fun delete(song: PracticeSong) {
        if (current?.id == song.id) close()
        store.folder(song).deleteRecursively()
        store.cacheFolder(song).deleteRecursively()
        library = library.filter { it.id != song.id }
        saveLibrary()
    }

    fun rename(song: PracticeSong, title: String) {
        val t = title.trim()
        if (t.isNotEmpty()) update(song.copy(title = t))
    }

    fun setOriginalKey(key: Int?) {
        current?.let { update(it.copy(originalKey = key)) }
    }

    // MARK: abrir / fechar

    fun open(song: PracticeSong) {
        pause()
        current = song
        position = 0.0
        duration = song.duration
        loopA = null; loopB = null
        semitones = song.semitones
        speed = song.speed
        stemMix.clear()
        StemKind.entries.filter { song.stemFiles.containsKey(it.key) }.forEach { stemMix[it] = StemMix() }
        useStems = song.hasStems
        rebuild()
    }

    fun close() {
        pause()
        releaseTracks()
        current = null
        position = 0.0; duration = 0.0
        loopA = null; loopB = null
    }

    private fun releaseTracks() {
        renderer.setTracks(emptyList())
        pcms.forEach { it.second.close() }
        pcms = emptyList()
        tracks = emptyList()
    }

    /** Prepara os PCMs (decodifica o que o Android tiver limpado do cache) e liga ao renderer. */
    private fun rebuild(thenPlay: Boolean = false) {
        val song = current ?: return
        releaseTracks()
        busy = "Preparando…"
        val wantStems = useStems && song.hasStems
        scope.launch {
            try {
                val list = withContext(Dispatchers.IO) {
                    val entries = mutableListOf<Pair<StemKind?, File>>()
                    if (wantStems) {
                        for (kind in StemKind.entries) {
                            val file = song.stemFiles[kind.key] ?: continue
                            val pcm = store.stemPcm(song, kind)
                            if (!pcm.exists()) {
                                AudioDecoder.decodeToPcm(app, Uri.fromFile(File(store.stemsFolder(song), file)), pcm)
                            }
                            entries += kind to pcm
                        }
                    }
                    if (entries.isEmpty()) {
                        val pcm = store.songPcm(song)
                        if (!pcm.exists()) AudioDecoder.decodeToPcm(app, Uri.fromFile(store.songFile(song)), pcm)
                        entries += null to pcm
                    }
                    entries.map { it.first to PcmFile(it.second) }
                }
                if (current?.id != song.id) { list.forEach { it.second.close() }; return@launch }
                if (list.size == 1 && list[0].first == null) useStems = false
                pcms = list
                tracks = list.map { PracticeRenderer.Track(it.second) }
                renderer.setTracks(tracks)
                list.maxOfOrNull { it.second.seconds }?.let { if (it > 0) duration = it }
                applyMix()
                applyTempo()
                applyLoop()
                if (thenPlay) play()
            } catch (e: Exception) {
                lastError = "Não consegui abrir a música: ${e.message ?: e.javaClass.simpleName}"
            } finally {
                busy = null
            }
        }
    }

    // MARK: transporte

    fun togglePlay() = if (isPlaying) pause() else play()

    fun play() {
        if (current == null || tracks.isEmpty() || busy != null) return
        var start = position
        if (start >= duration - 0.05) start = 0.0
        val a = loopA; val b = loopB
        if (a != null && b != null && (start < a || start >= b - 0.05)) start = a
        position = start
        renderer.seek((start * SR).toLong())
        output.start()
        isPlaying = true
        startTicker()
    }

    fun pause() {
        if (isPlaying) position = currentPosition()
        output.stop()
        isPlaying = false
        ticker?.cancel()
        ticker = null
    }

    fun seek(t: Double) {
        val v = t.coerceIn(0.0, (duration - 0.01).coerceAtLeast(0.0))
        position = v
        if (isPlaying) renderer.seek((v * SR).toLong())
    }

    fun skip(delta: Double) = seek((if (isPlaying) currentPosition() else position) + delta)

    private fun currentPosition(): Double =
        if (!isPlaying) position else renderer.positionAt(output.playedFrames()) / SR

    private fun startTicker() {
        ticker?.cancel()
        ticker = scope.launch {
            while (isActive && isPlaying) {
                position = currentPosition().coerceIn(0.0, duration)
                if (renderer.ended) {
                    output.stop()
                    isPlaying = false
                    position = 0.0
                    break
                }
                delay(50)
            }
        }
    }

    // MARK: tom e velocidade

    fun changeSemitones(v: Int) {
        semitones = v.coerceIn(SEMITONES.first, SEMITONES.last)
        applyTempo(); persist()
    }

    fun changeSpeed(v: Double) {
        speed = ((v.coerceIn(SPEED_MIN, SPEED_MAX)) * 100).roundToInt() / 100.0
        applyTempo(); persist()
    }

    private fun applyTempo() = renderer.setTempo(speed, semitones)

    private var persistJob: Job? = null
    private fun persist() {
        val s = current ?: return
        val updated = s.copy(semitones = semitones, speed = speed)
        current = updated
        library = library.map { if (it.id == updated.id) updated else it }
        persistJob?.cancel()
        persistJob = scope.launch { delay(800); withContext(Dispatchers.IO) { saveLibrary() } }
    }

    // MARK: loop A-B

    fun setLoopA() {
        val t = currentPosition()
        loopA = t
        loopB?.let { if (it - t < MIN_LOOP) loopB = null }
        applyLoop()
    }

    fun setLoopB() {
        val t = currentPosition()
        val a = loopA ?: run { lastError = "Marque o ponto A primeiro."; return }
        if (t - a < MIN_LOOP) {
            lastError = "O ponto B precisa estar pelo menos meio segundo depois do A."
            return
        }
        loopB = t
        applyLoop()
    }

    fun clearLoop() {
        loopA = null; loopB = null
        applyLoop()
    }

    private fun applyLoop() {
        val a = loopA; val b = loopB
        if (a != null && b != null) renderer.setLoop((a * SR).toLong(), (b * SR).toLong())
        else renderer.setLoop(-1, -1)
        if (isPlaying && a != null && b != null) {
            val t = currentPosition()
            if (t < a || t >= b) seek(a)
        }
    }

    // MARK: stems

    fun changeUseStems(on: Boolean) {
        if (current?.hasStems != true || on == useStems) return
        val was = isPlaying
        pause()
        useStems = on
        rebuild(thenPlay = was)
    }

    fun setStemVolume(kind: StemKind, v: Float) {
        stemMix[kind] = (stemMix[kind] ?: StemMix()).copy(volume = v.coerceIn(0f, 1.5f)); applyMix()
    }

    fun toggleMute(kind: StemKind) {
        val s = stemMix[kind] ?: StemMix(); stemMix[kind] = s.copy(muted = !s.muted); applyMix()
    }

    fun toggleSolo(kind: StemKind) {
        val s = stemMix[kind] ?: StemMix(); stemMix[kind] = s.copy(solo = !s.solo); applyMix()
    }

    /** Atalho: tira um instrumento (violão para tocar junto, voz para karaokê). */
    fun removeOnly(kind: StemKind) {
        for (k in stemMix.keys.toList()) stemMix[k] = stemMix[k]!!.copy(solo = false, muted = k == kind)
        applyMix()
    }

    fun resetMix() {
        for (k in stemMix.keys.toList()) stemMix[k] = StemMix()
        applyMix()
    }

    fun isAudible(kind: StemKind): Boolean {
        val st = stemMix[kind] ?: return false
        val anySolo = stemMix.values.any { it.solo }
        return !st.muted && !(anySolo && !st.solo) && st.volume > 0
    }

    private fun applyMix() {
        pcms.forEachIndexed { i, (kind, _) ->
            tracks.getOrNull(i)?.gain = if (kind == null) 1f else if (isAudible(kind)) stemMix[kind]?.volume ?: 1f else 0f
        }
    }

    // MARK: separação (IA)

    val modelReady: Boolean get() = models.isReady

    fun separateCurrent() {
        val song = current ?: return
        if (separating) return
        pause()
        separating = true
        cancelFlag = false
        separationProgress = 0.0
        separationJob = scope.launch {
            try {
                if (!models.isReady) {
                    separationStage = "Baixando o modelo de IA…"
                    withContext(Dispatchers.IO) {
                        models.download({ p -> scope.launch { separationProgress = p } }, { cancelFlag })
                    }
                }
                if (cancelFlag) return@launch
                separationStage = "Preparando a música…"
                separationProgress = 0.0
                // A IA roda num processo à parte (SeparationService): se faltar memória, só ele cai.
                SeparationService.start(app, song.id)
                watchSeparation(song.id)
            } catch (e: InterruptedException) {
                // cancelado
            } catch (e: Exception) {
                lastError = "A separação falhou: ${e.message ?: e.javaClass.simpleName}"
            } finally {
                separating = false
                separationJob = null
            }
        }
    }

    /** Acompanha o arquivo de status do serviço até terminar (ou o processo da IA morrer). */
    private suspend fun watchSeparation(songId: String) {
        val file = SeparationService.statusFile(app)
        var missingSince = 0L
        while (true) {
            delay(400)
            val st = try { org.json.JSONObject(file.readText()) } catch (_: Exception) { continue }
            when (st.optString("state")) {
                "starting", "running" -> {
                    separationProgress = st.optDouble("progress", 0.0)
                    st.optString("stage").takeIf { it.isNotEmpty() }?.let { separationStage = it }
                    // O processo da IA ainda existe? (o Android pode tê-lo matado por falta de memória)
                    if (iaProcessAlive()) {
                        missingSince = 0L
                    } else {
                        if (missingSince == 0L) missingSince = System.currentTimeMillis()
                        if (System.currentTimeMillis() - missingSince > 4000) {
                            lastError = iaDeathMessage()
                            file.delete()
                            return
                        }
                    }
                }
                "done" -> {
                    val stems = st.optJSONObject("stems")
                    val map = mutableMapOf<String, String>()
                    stems?.keys()?.forEach { k -> map[k] = stems.getString(k) }
                    file.delete()
                    finishSeparation(songId, map)
                    return
                }
                "cancelled" -> { file.delete(); return }
                "error" -> {
                    lastError = st.optString("message", "A separação falhou.")
                    file.delete()
                    return
                }
                else -> return
            }
        }
    }

    private fun iaProcessAlive(): Boolean {
        val am = app.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
        return am.runningAppProcesses?.any { it.processName.endsWith(":ia") } == true
    }

    /** Explica por que o processo da IA sumiu (Android 11+: motivo registrado pelo sistema). */
    private fun iaDeathMessage(): String {
        var reason = ""
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            val am = app.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
            val info = am.getHistoricalProcessExitReasons(app.packageName, 0, 10).firstOrNull { it.processName.endsWith(":ia") }
            if (info != null) {
                reason = when (info.reason) {
                    android.app.ApplicationExitInfo.REASON_LOW_MEMORY ->
                        "O Android fechou a separação por falta de memória. Feche outros apps (principalmente jogos e o navegador) e tente de novo."
                    android.app.ApplicationExitInfo.REASON_CRASH_NATIVE, android.app.ApplicationExitInfo.REASON_CRASH ->
                        "A IA travou neste aparelho (${info.description ?: "erro interno"})."
                    android.app.ApplicationExitInfo.REASON_SIGNALED -> "O sistema interrompeu a separação (${info.description ?: "sinal"})."
                    else -> "A separação foi interrompida (motivo ${info.reason}: ${info.description ?: "-"})."
                }
                android.util.Log.w("Pestana", "IA morreu: motivo=${info.reason} ${info.description} pss=${info.pss}kB rss=${info.rss}kB")
            }
        }
        return reason.ifEmpty { "A separação foi interrompida pelo sistema. Feche outros apps e tente de novo." }
    }

    /** Ao abrir o app: se uma separação continua rodando no serviço, volta a acompanhar. */
    fun resumeSeparationIfRunning() {
        val f = SeparationService.statusFile(app)
        if (separating || !f.exists()) return
        val st = try { org.json.JSONObject(f.readText()) } catch (_: Exception) { return }
        val songId = st.optString("songId")
        if (st.optString("state") in listOf("starting", "running", "done")) {
            separating = true
            separationJob = scope.launch {
                try { watchSeparation(songId) } finally { separating = false; separationJob = null }
            }
        } else {
            f.delete()
        }
    }

    fun cancelSeparation() {
        cancelFlag = true
        SeparationService.cancel(app)
    }

    private fun finishSeparation(songId: String, map: Map<String, String>) {
        val song = library.firstOrNull { it.id == songId } ?: return
        if (map.isEmpty()) return
        val updated = song.copy(stemFiles = map)
        update(updated)
        if (current?.id == songId) {
            stemMix.clear()
            StemKind.entries.filter { map.containsKey(it.key) }.forEach { stemMix[it] = StemMix() }
            useStems = true
            rebuild()
        }
    }

    fun deleteStems() {
        val song = current ?: return
        pause()
        store.stemsFolder(song).deleteRecursively()
        StemKind.entries.forEach { store.stemPcm(song, it).delete() }
        update(song.copy(stemFiles = emptyMap()))
        stemMix.clear()
        useStems = false
        rebuild()
    }

    /** Arquivos para levar ao Estúdio: stems audíveis (modo stems) ou a música completa. */
    fun filesForStudio(): List<Pair<String, File>> {
        val song = current ?: return emptyList()
        if (useStems && song.hasStems) {
            val list = StemKind.entries.mapNotNull { kind ->
                val f = song.stemFiles[kind.key] ?: return@mapNotNull null
                if (!isAudible(kind)) null else kind.title to File(store.stemsFolder(song), f)
            }
            if (list.isNotEmpty()) return list
        }
        return listOf(song.title to store.songFile(song))
    }

    /** Aba saiu da tela / app em segundo plano. */
    fun deactivate() = pause()

    fun release() {
        cancelFlag = true
        pause()
        releaseTracks()
    }
}
