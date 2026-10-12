package com.pestana.estudio.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

class SlidingWindowTest {
    @Test
    fun framesAdvanceByHopWhateverTheBlockSize() {
        for (block in listOf(1, 480, 1024, 3000, 5000)) {
            val w = SlidingWindow(4096, 1024)
            val starts = mutableListOf<Float>()
            var t = 0
            while (t < 20000) {
                val n = minOf(block, 20000 - t)
                val b = FloatArray(n) { (t + it).toFloat() }
                w.feed(b, n) { f ->
                    // cada janela é contínua: amostras consecutivas
                    for (i in 1 until f.size) assertEquals(f[i - 1] + 1, f[i])
                    starts.add(f[0])
                }
                t += n
            }
            assertEquals((20000 - 4096) / 1024 + 1, starts.size)
            starts.forEachIndexed { i, s -> assertEquals(i * 1024f, s) }
        }
    }

    @Test
    fun microphonePipelineFindsTheString() {
        // Simula o caminho do afinador: blocos de 1024 do microfone → janelas → YIN → leitura.
        val sr = 48000.0
        val f0 = Pitch.hz(50, 440.0) * Math.pow(2.0, -12 / 1200.0) // Ré 12 cents abaixo
        val w = SlidingWindow(4096, 1024)
        val logic = TunerLogic()
        var last: TunerReading? = null
        var pos = 0
        repeat(30) {
            val b = FloatArray(1024) { i ->
                val x = (pos + i) / sr
                (0.2 * (sin(2 * PI * f0 * x) + 0.4 * sin(4 * PI * f0 * x))).toFloat()
            }
            pos += 1024
            w.feed(b, b.size) { frame ->
                val r = logic.feed(Yin.detect(frame, sr), Tuning.all[0], 440.0, true, 0)
                if (r is TunerLogic.Result.Reading) last = r.reading
            }
        }
        val r = last!!
        assertEquals(50, r.targetMidi)
        assertEquals(2, r.stringIndex)
        assertTrue("cents ${r.centsPrecise}", abs(r.centsPrecise + 12) < 1.0)
    }
}
