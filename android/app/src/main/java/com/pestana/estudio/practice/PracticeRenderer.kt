package com.pestana.estudio.practice

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.common.util.UnstableApi
import com.pestana.estudio.audio.PcmFile
import com.pestana.estudio.core.AudioRenderer
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.pow

/**
 * Toca a música (ou os stems, somados com volume próprio) a partir do PCM em disco, com
 * tom e velocidade independentes (Sonic, o mesmo algoritmo do ExoPlayer/Media3) e loop A-B
 * sem emenda. Saída estéreo intercalada a 44,1 kHz.
 */
@OptIn(UnstableApi::class)
class PracticeRenderer : AudioRenderer {
    class Track(val pcm: PcmFile) {
        @Volatile var gain: Float = 1f
    }

    /** Ponto de referência: a amostra de saída [out] corresponde à posição [src] da música. */
    private class Checkpoint(val out: Long, val src: Long, val rate: Double)

    private val lock = Any()
    private var tracks: List<Track> = emptyList()
    private var total = 0L
    private var pos = 0L
    private var loopA = -1L
    private var loopB = -1L
    @Volatile var ended = false
        private set

    private var speed = 1.0
    private var semitones = 0
    private var sonicDirty = true
    private val sonic = SonicAudioProcessor()
    private var sonicActive = false

    private val block = 1024
    private val mix = FloatArray(block * 2)
    private var inBytes = ByteBuffer.allocateDirect(block * 4).order(ByteOrder.nativeOrder())
    private var fifo = FloatArray(16384)
    private var fifoLen = 0
    private var produced = 0L // amostras de saída já geradas (estéreo = quadros)
    private val checkpoints = ArrayDeque<Checkpoint>()
    /** quadro do stream de saída − índice em [produced]: liga o relógio do AudioTrack às posições. */
    private var streamOffset = 0L

    fun setTracks(list: List<Track>) = synchronized(lock) {
        tracks = list
        total = list.maxOfOrNull { it.pcm.frames } ?: 0L
    }

    fun setLoop(a: Long, b: Long) = synchronized(lock) {
        loopA = a; loopB = b
    }

    fun setTempo(speed: Double, semitones: Int) = synchronized(lock) {
        if (speed != this.speed || semitones != this.semitones) {
            this.speed = speed
            this.semitones = semitones
            sonicDirty = true
        }
    }

    /** Recomeça a leitura em [frame] (descarta o que estava no buffer). */
    fun seek(frame: Long) = synchronized(lock) {
        pos = frame.coerceIn(0, maxOf(0, total - 1))
        fifoLen = 0
        ended = false
        sonicDirty = true
        checkpoints.clear()
        checkpoints.addLast(Checkpoint(produced, pos, 1.0))
    }

    /** Posição (em quadros da música) do que está saindo no alto-falante agora. */
    fun positionAt(streamPlayed: Long): Long = synchronized(lock) {
        val playedFrames = streamPlayed - streamOffset
        var cp: Checkpoint? = null
        for (c in checkpoints) { if (c.out <= playedFrames) cp = c else break }
        val c = cp ?: return pos
        // descarta pontos antigos
        while (checkpoints.size > 2 && checkpoints.first() !== c && checkpoints.elementAt(1).out <= playedFrames) {
            checkpoints.removeFirst()
        }
        val p = c.src + ((playedFrames - c.out) * c.rate).toLong()
        return if (loopB > 0 && p >= loopB) loopA + (p - loopB) else p.coerceAtMost(total)
    }

    private fun reconfigureSonic() {
        sonicDirty = false
        val pitch = 2.0.pow(semitones / 12.0).toFloat()
        sonic.setSpeed(speed.toFloat())
        sonic.setPitch(pitch)
        sonicActive = try {
            sonic.configure(AudioProcessor.AudioFormat(PcmFile.SAMPLE_RATE, 2, C.ENCODING_PCM_16BIT))
            sonic.flush()
            sonic.isActive
        } catch (_: Exception) {
            false
        }
    }

    private fun pushFifo(src: FloatArray, n: Int, srcStart: Long, srcFrames: Int) {
        if (n <= 0) return
        if (fifoLen + n * 2 > fifo.size) fifo = fifo.copyOf(maxOf(fifo.size * 2, fifoLen + n * 2))
        System.arraycopy(src, 0, fifo, fifoLen, n * 2)
        fifoLen += n * 2
        checkpoints.addLast(Checkpoint(produced, srcStart, srcFrames.toDouble() / n))
        if (checkpoints.size > 512) checkpoints.removeFirst()
        produced += n
    }

    private var outFloats = FloatArray(block * 4)

    /** Lê até um bloco da música (parando no B do loop) e passa pelo Sonic. */
    private fun produce(): Boolean {
        if (sonicDirty) reconfigureSonic()
        val end = if (loopB > 0) loopB else total
        if (pos >= end) {
            if (loopB > 0) {
                pos = loopA
            } else {
                return false
            }
        }
        val n = minOf(block.toLong(), end - pos).toInt()
        java.util.Arrays.fill(mix, 0, n * 2, 0f)
        for (t in tracks) t.pcm.mixInto(pos, n, t.gain, mix)
        val start = pos
        pos += n
        if (!sonicActive) {
            pushFifo(mix, n, start, n)
            return true
        }
        if (inBytes.capacity() < n * 4) inBytes = ByteBuffer.allocateDirect(n * 4).order(ByteOrder.nativeOrder())
        inBytes.clear()
        for (i in 0 until n * 2) {
            val v = (mix[i] * 32767f).toInt().coerceIn(-32768, 32767)
            inBytes.putShort(v.toShort())
        }
        inBytes.flip()
        sonic.queueInput(inBytes)
        val out = sonic.output.order(ByteOrder.nativeOrder())
        val samples = out.remaining() / 2
        if (outFloats.size < samples) outFloats = FloatArray(samples)
        for (i in 0 until samples) outFloats[i] = out.short / 32768f
        pushFifo(outFloats, samples / 2, start, n)
        return true
    }

    override fun render(out: FloatArray, frames: Int, startFrame: Long) = synchronized(lock) {
        val need = frames * 2
        var guard = 0
        while (fifoLen < need && !ended && guard++ < 64) {
            if (!produce()) {
                ended = fifoLen == 0
                break
            }
        }
        streamOffset = startFrame - (produced - fifoLen / 2)
        val take = minOf(need, fifoLen)
        System.arraycopy(fifo, 0, out, 0, take)
        java.util.Arrays.fill(out, take, need, 0f)
        System.arraycopy(fifo, take, fifo, 0, fifoLen - take)
        fifoLen -= take
        if (take < need && pos >= total && loopB <= 0) ended = true
    }
}
