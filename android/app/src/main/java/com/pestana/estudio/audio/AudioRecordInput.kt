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
    private class Session {
        @Volatile var active = true
    }

    @Volatile private var session: Session? = null

    override var sampleRate: Int = preferredRate
        private set

    override val isRunning: Boolean get() = session?.active == true

    /** Quem chama deve ter verificado a permissão RECORD_AUDIO antes. */
    @SuppressLint("MissingPermission")
    override fun start(onBlock: (FloatArray, Int) -> Unit): Boolean {
        synchronized(lock) {
            if (session?.active == true) return true
            // Float primeiro; aparelhos que não aceitam float na entrada caem para 16 bits.
            var record: AudioRecord? = null
            var useFloat = true
            loop@ for (encoding in listOf(AudioFormat.ENCODING_PCM_FLOAT, AudioFormat.ENCODING_PCM_16BIT)) {
                for (rate in listOf(preferredRate, 48000, 44100).distinct()) {
                    val r = open(rate, encoding) ?: continue
                    record = r
                    sampleRate = rate
                    useFloat = encoding == AudioFormat.ENCODING_PCM_FLOAT
                    break@loop
                }
            }
            val rec = record ?: return false
            try {
                rec.startRecording()
            } catch (_: Exception) {
                rec.release()
                return false
            }
            val sess = Session()
            session = sess
            val isFloat = useFloat
            thread = Thread({
                Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
                val buf = FloatArray(1024)
                val shorts = ShortArray(1024)
                try {
                    while (sess.active) {
                        val n = if (isFloat) {
                            rec.read(buf, 0, buf.size, AudioRecord.READ_BLOCKING)
                        } else {
                            val k = rec.read(shorts, 0, shorts.size, AudioRecord.READ_BLOCKING)
                            for (i in 0 until k) buf[i] = shorts[i] / 32768f
                            k
                        }
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
                    sess.active = false
                }
            }, "pestana-mic").also { it.start() }
            return true
        }
    }

    @SuppressLint("MissingPermission")
    private fun open(rate: Int, encoding: Int): AudioRecord? {
        val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, encoding)
        if (min <= 0) return null
        val bytesPerSample = if (encoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
        val r = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                rate,
                AudioFormat.CHANNEL_IN_MONO,
                encoding,
                maxOf(min, 8192 * bytesPerSample),
            )
        } catch (_: Exception) {
            return null
        }
        if (r.state == AudioRecord.STATE_INITIALIZED) return r
        r.release()
        return null
    }

    override fun stop() {
        val t: Thread?
        synchronized(lock) {
            session?.active = false
            session = null
            t = thread
            thread = null
        }
        t?.join(500)
    }
}
