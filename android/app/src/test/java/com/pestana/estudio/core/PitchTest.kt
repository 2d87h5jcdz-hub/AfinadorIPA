package com.pestana.estudio.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.pow
import kotlin.math.sin

class PitchTest {
    private val sr = 48000.0

    /** "Voz" sintética: notas com harmônicos e vibrato leve, desafinadas em [cents]. */
    private fun voice(notes: List<Int>, cents: Double, secPerNote: Double = 0.6): FloatArray {
        val per = (secPerNote * sr).toInt()
        val out = FloatArray(per * notes.size)
        var phase = 0.0
        for ((k, m) in notes.withIndex()) for (i in 0 until per) {
            val t = i / sr
            val f = 440 * 2.0.pow((m - 69 + cents / 100) / 12) * (1 + 0.003 * sin(2 * PI * 5.5 * t))
            phase += 2 * PI * f / sr
            val env = minOf(1.0, i / 800.0, (per - i) / 800.0)
            out[k * per + i] = (0.3 * env * (sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase))).toFloat()
        }
        return out
    }

    private fun medianMidi(a: FloatArray, from: Int, to: Int): Float {
        val v = a.slice(from until to).filter { !it.isNaN() }.sorted()
        return v[v.size / 2]
    }

    @Test
    fun analysisFindsTheSungNotes() {
        val x = voice(listOf(60, 64, 67), cents = 0.0)
        val an = PitchDsp.analyze(x, sr)
        val per = an.midi.size / 3
        for ((k, m) in listOf(60, 64, 67).withIndex()) {
            val med = medianMidi(an.midi, k * per + per / 4, k * per + 3 * per / 4)
            assertTrue("nota $m: $med", abs(med - m) < 0.1f)
        }
    }

    @Test
    fun keyDetectionOnCMajorMelody() {
        val x = voice(listOf(60, 62, 64, 65, 67, 69, 71, 72, 67, 64, 60), cents = 0.0, secPerNote = 0.4)
        val key = PitchDsp.detectKey(PitchDsp.analyze(x, sr).midi)
        assertNotNull("tom", key)
        assertEquals(0, key!!.first)
        assertEquals(PitchScale.MAJOR, key.second)
    }

    @Test
    fun correctionMovesNotesTowardsScale() {
        // Canta 35 cents acima; com 100% de intensidade deve voltar a ~0.
        val x = voice(listOf(60, 64, 67), cents = 35.0)
        val y = PitchDsp.process(arrayOf(x), sr, key = 0, scale = PitchScale.MAJOR, strength = 1f)[0]
        val an = PitchDsp.analyze(y, sr)
        val per = an.midi.size / 3
        for ((k, m) in listOf(60, 64, 67).withIndex()) {
            val med = medianMidi(an.midi, k * per + per / 4, k * per + 3 * per / 4)
            assertTrue("nota $m depois: $med", abs(med - m) < 0.08f)
        }
    }

    @Test
    fun zeroStrengthIsTransparent() {
        val x = voice(listOf(62, 66), cents = 30.0)
        val y = PitchDsp.process(arrayOf(x), sr, key = 2, scale = PitchScale.MAJOR, strength = 0f)[0]
        var err = 0.0; var pw = 0.0
        for (i in 2000 until x.size - 2000) { err += (x[i] - y[i]).let { it * it }; pw += x[i] * x[i] }
        assertTrue("erro relativo ${err / pw}", err / pw < 1e-3)
    }

    @Test
    fun signatureMatchesIos() {
        val s = PitchSettings(enabled = true, key = 9, scale = PitchScale.MINOR, strength = 0.8f)
        assertEquals("9min80", s.signature)
        assertEquals(null, PitchSettings(enabled = true).signature)
    }
}
