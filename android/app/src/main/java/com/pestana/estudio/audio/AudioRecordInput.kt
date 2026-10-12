package com.pestana.estudio.audio

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Process

/**
 * Microfone com AudioRecord em float. Usa a fonte VOICE_RECOGNITION, que na maioria dos
 * aparelhos desliga o controle automático de ganho e a supressão de ruído — melhor para afinar.
 */
class AudioRecordInput(private val preferredRate: Int = 48000) : AudioInput {
    private val lock = Any()
    private var thread: Thread? = null
    @Volatile private var running = false

    override var sampleRate: Int = preferredRate
        private set

    override val isRunning: Boolean get() = running

    /** Quem chama deve ter verificado a permissão RECORD_AUDIO antes. */
    @SuppressLint("MissingPermission")
    override fun start(onBlock: (FloatArray, Int) -> Unit): Boolean {
        synchronized(lock) {
            if (running) return true
            var record: AudioRecord? = null
            for (rate in listOf(preferredRate, 48000, 44100).distinct()) {
                val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT)
                if (min <= 0) continue
                val r = try {
                    AudioRecord(
                        MediaRecorder.AudioSource.VOICE_RECOGNITION,
                        rate,
                        AudioFormat.CHANNEL_IN_MONO,
                        AudioFormat.ENCODING_PCM_FLOAT,
                        maxOf(min, 8192 * 4),
                    )
                } catch (_: Exception) {
                    null
                }
                if (r != null && r.state == AudioRecord.STATE_INITIALIZED) {
                    record = r
                    sampleRate = rate
                    break
                }
                r?.release()
            }
            val rec = record ?: return false
            try {
                rec.startRecording()
            } catch (_: Exception) {
                rec.release()
                return false
            }
            running = true
            thread = Thread({
                Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
                val buf = FloatArray(1024)
                try {
                    while (running) {
                        val n = rec.read(buf, 0, buf.size, AudioRecord.READ_BLOCKING)
                        if (n < 0) break
                        if (n > 0) onBlock(buf, n)
                    }
                } catch (_: Exception) {
                } finally {
                    try {
                        rec.stop()
                    } catch (_: Exception) {
                    }
                    rec.release()
                    running = false
                }
            }, "pestana-mic").also { it.start() }
            return true
        }
    }

    override fun stop() {
        val t: Thread?
        synchronized(lock) {
            running = false
            t = thread
            thread = null
        }
        t?.join(500)
    }
}
