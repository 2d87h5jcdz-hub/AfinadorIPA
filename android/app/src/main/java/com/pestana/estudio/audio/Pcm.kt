package com.pestana.estudio.audio

import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.ShortBuffer
import java.nio.channels.FileChannel

/**
 * Áudio já decodificado em disco: PCM 16 bits, estéreo intercalado, sem cabeçalho
 * (44,1 kHz no Treino, 48 kHz no Estúdio).
 * Lido por mapeamento de memória (acesso aleatório instantâneo para seek e loop A-B).
 */
class PcmFile(val file: File, val sampleRate: Int = SAMPLE_RATE) : Closeable {
    companion object {
        const val SAMPLE_RATE = 44_100
        const val BYTES_PER_FRAME = 4
    }

    private val raf = RandomAccessFile(file, "r")
    private val shorts: ShortBuffer = raf.channel.map(FileChannel.MapMode.READ_ONLY, 0, raf.length())
        .order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()

    val frames: Long = raf.length() / BYTES_PER_FRAME
    val seconds: Double get() = frames.toDouble() / sampleRate

    /** Lê [count] quadros a partir de [start]; o que passar do fim vira silêncio. */
    fun read(start: Long, count: Int, left: FloatArray, right: FloatArray, lOff: Int = 0) {
        var i = 0
        while (i < count) {
            val f = start + i
            if (f < 0 || f >= frames) {
                left[lOff + i] = 0f; right[lOff + i] = 0f
            } else {
                val idx = (f * 2).toInt()
                left[lOff + i] = shorts.get(idx) / 32768f
                right[lOff + i] = shorts.get(idx + 1) / 32768f
            }
            i++
        }
    }

    /** Soma (com ganho) [count] quadros em out intercalado (L R L R…). */
    fun mixInto(start: Long, count: Int, gain: Float, out: FloatArray) {
        if (gain == 0f) return
        val g = gain / 32768f
        for (i in 0 until count) {
            val f = start + i
            if (f < 0 || f >= frames) continue
            val idx = (f * 2).toInt()
            out[2 * i] += shorts.get(idx) * g
            out[2 * i + 1] += shorts.get(idx + 1) * g
        }
    }

    override fun close() = raf.close()
}

/** Grava PCM 16 bits estéreo intercalado (formato do [PcmFile]). */
class PcmWriter(file: File) : Closeable {
    private val out = BufferedOutputStream(FileOutputStream(file), 1 shl 16)
    private var bytes = ByteBuffer.allocate(8192 * 4).order(ByteOrder.LITTLE_ENDIAN)
    var frames = 0L
        private set

    fun write(left: FloatArray, right: FloatArray, n: Int, off: Int = 0) {
        if (bytes.capacity() < n * 4) bytes = ByteBuffer.allocate(n * 4).order(ByteOrder.LITTLE_ENDIAN)
        bytes.clear()
        for (i in 0 until n) {
            bytes.putShort(toShort(left[off + i]))
            bytes.putShort(toShort(right[off + i]))
        }
        out.write(bytes.array(), 0, n * 4)
        frames += n
    }

    private fun toShort(v: Float): Short {
        val x = (v * 32767f).let { if (it > 32767f) 32767f else if (it < -32768f) -32768f else it }
        return Math.round(x).toShort()
    }

    override fun close() = out.close()
}
