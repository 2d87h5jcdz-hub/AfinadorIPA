package com.pestana.estudio.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Process
import com.pestana.estudio.core.AudioRenderer

/**
 * Stream de saída contínuo com AudioTrack em float. Uma thread de prioridade de áudio pede
 * blocos ao [renderer] e escreve no AudioTrack (escrita bloqueante = o relógio é o próprio
 * hardware, então o tempo das batidas não depende de timers).
 *
 * @param stopWhenIdle desliga sozinho depois que o renderer fica em silêncio (poupa bateria).
 */
class AudioTrackOutput(
    override val sampleRate: Int,
    private val renderer: AudioRenderer,
    private val stopWhenIdle: Boolean,
    private val usage: Int = AudioAttributes.USAGE_MEDIA,
    /** 1 = mono, 2 = estéreo intercalado (o renderer recebe frames × canais amostras). */
    private val channels: Int = 1,
    /** false = buffer folgado (player de músicas: prioriza não engasgar em vez de latência). */
    private val lowLatency: Boolean = true,
) : AudioOutput {
    /** Uma ligação do stream; cada uma tem sua thread e seu AudioTrack. */
    private class Session {
        @Volatile var active = true
        @Volatile var track: AudioTrack? = null
        var thread: Thread? = null
    }

    private val lock = Any()
    @Volatile private var session: Session? = null

    override val isRunning: Boolean get() = session?.active == true

    override fun start() {
        synchronized(lock) {
            if (session?.active == true) return
            val s = Session()
            session = s
            s.thread = Thread({ loop(s) }, "pestana-audio-out").also { it.start() }
        }
    }

    override fun stop() {
        val s: Session?
        synchronized(lock) {
            s = session
            session = null
        }
        s?.active = false
        s?.thread?.join(500)
    }

    override fun playedFrames(): Long {
        val t = session?.track ?: return 0
        return try {
            t.playbackHeadPosition.toLong() and 0xFFFFFFFFL
        } catch (_: IllegalStateException) {
            0
        }
    }

    private fun loop(s: Session) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val mask = if (channels == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val minBytes = AudioTrack.getMinBufferSize(sampleRate, mask, AudioFormat.ENCODING_PCM_FLOAT)
        val block = 256
        val t = try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(usage)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(mask)
                        .build(),
                )
                .setBufferSizeInBytes(maxOf(minBytes, (if (lowLatency) block * 2 else 8192) * 4 * channels))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setPerformanceMode(
                    if (lowLatency) AudioTrack.PERFORMANCE_MODE_LOW_LATENCY else AudioTrack.PERFORMANCE_MODE_NONE,
                )
                .build()
        } catch (e: Exception) {
            s.active = false
            return
        }
        s.track = t
        val buf = FloatArray(block * channels)
        var written = 0L
        var idleFrames = 0L
        try {
            t.play()
            while (s.active) {
                renderer.render(buf, block, written)
                val n = t.write(buf, 0, block * channels, AudioTrack.WRITE_BLOCKING)
                if (n < 0) break
                written += block
                if (stopWhenIdle && renderer.isIdle) {
                    idleFrames += block
                    if (idleFrames > sampleRate / 2) break
                } else {
                    idleFrames = 0
                }
            }
        } catch (_: Exception) {
        } finally {
            s.active = false
            s.track = null
            try {
                t.pause()
                t.flush()
                t.stop()
            } catch (_: Exception) {
            }
            t.release()
        }
    }

    companion object {
        /** Taxa nativa do aparelho (evita reamostragem e a latência extra que ela traz). */
        fun nativeSampleRate(context: Context): Int {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            return am.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull()?.takeIf { it > 0 }
                ?: 48000
        }
    }
}
