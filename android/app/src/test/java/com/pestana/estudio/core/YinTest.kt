package com.pestana.estudio.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.sin

class YinTest {
    private val sr = 48000.0

    /** Corda sintética: fundamental + harmônicos decrescentes. */
    private fun string(freq: Double, n: Int = 4096, amp: Double = 0.3): FloatArray =
        FloatArray(n) { i ->
            val t = i / sr
            (amp * (sin(2 * PI * freq * t) + 0.5 * sin(4 * PI * freq * t) + 0.3 * sin(6 * PI * freq * t))).toFloat()
        }

    private fun centsBetween(a: Double, b: Double) = 1200 * ln(a / b) / ln(2.0)

    @Test
    fun detectsAllOpenStringsWithinOneCent() {
        for (midi in listOf(38, 40, 45, 50, 55, 59, 64, 76)) {
            val f = Pitch.hz(midi, 440.0)
            val got = Yin.detect(string(f), sr)
            assertNotNull("midi $midi", got)
            val c = centsBetween(got!!, f)
            assertTrue("midi $midi: esperado $f Hz, veio $got Hz ($c cents)", abs(c) < 1.0)
        }
    }

    @Test
    fun detectsSlightlyDetunedString() {
        val f = Pitch.hz(45, 440.0) * Math.pow(2.0, 20 / 1200.0) // +20 cents
        val r = TunerLogic.read(Yin.detect(string(f), sr)!!, Tuning.all[0], 440.0, true, 0)
        assertEquals(45, r.targetMidi)
        assertEquals(1, r.stringIndex)
        assertTrue("cents ${r.centsPrecise}", abs(r.centsPrecise - 20) < 1.0)
    }

    @Test
    fun silenceIsNull() {
        assertNull(Yin.detect(FloatArray(4096), sr))
        assertNull(Yin.detect(string(110.0, amp = 0.001), sr))
    }

    @Test
    fun manualModeFoldsOctaves() {
        // Por corda: tocando um Mi uma oitava acima na 6ª corda, o alvo segue a oitava tocada.
        val r = TunerLogic.read(Pitch.hz(52, 440.0), Tuning.all[0], 440.0, false, 0)
        assertEquals(52, r.targetMidi)
        assertEquals(0, r.cents)
    }

    @Test
    fun a4ReferenceShiftsTarget() {
        val r = TunerLogic.read(432.0, Tuning.all[0], 432.0, true, 0)
        assertEquals(69, r.targetMidi)
        assertEquals(0, r.cents)
        assertNull(r.stringIndex) // Lá4 está longe de qualquer corda solta
    }
}
