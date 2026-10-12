package com.pestana.estudio.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MetronomeTest {
    private fun runClicks(sr: Double, bpm: Double, beats: Int, seconds: Double, block: Int): List<ClickRenderer.BeatEvent> {
        val r = ClickRenderer(sr)
        r.setTempo(bpm, beats)
        r.start()
        val buf = FloatArray(block)
        var frame = 0L
        val total = (sr * seconds).toLong()
        while (frame < total) {
            r.render(buf, block, frame)
            frame += block
        }
        return r.events.filter { it.frame < total }
    }

    @Test
    fun beatsLandOnExactSamples() {
        // 120 BPM a 48 kHz = 24000 amostras por batida, independente do tamanho do bloco.
        for (block in listOf(64, 192, 997, 4096)) {
            val ev = runClicks(48000.0, 120.0, 4, 10.0, block)
            assertEquals(20, ev.size)
            ev.forEachIndexed { i, e ->
                assertEquals(i * 24000L, e.frame)
                assertEquals(i % 4, e.beat)
            }
        }
    }

    @Test
    fun fractionalTempoDoesNotDrift() {
        // 97 BPM a 44,1 kHz: 27278,35… amostras por batida — o erro não acumula.
        val ev = runClicks(44100.0, 97.0, 3, 60.0, 256)
        val spb = 44100.0 * 60 / 97
        ev.forEachIndexed { i, e -> assertTrue("batida $i em ${e.frame}", kotlin.math.abs(e.frame - i * spb) <= 1.0) }
        assertEquals(2, ev[2].beat)
        assertEquals(0, ev[3].beat)
    }

    @Test
    fun sixEightClicksEighths() {
        val ev = runClicks(48000.0, 60.0, 6, 3.0, 512)
        assertEquals(6, ev.size)
        assertEquals(24000L, ev[1].frame)
    }

    @Test
    fun tapTempo() {
        val t = TapTempo()
        val step = 500_000_000L // 0,5 s = 120 BPM
        t.tap(0)
        assertEquals(120.0, t.tap(step)!!, 0.0)
        assertEquals(120.0, t.tap(2 * step)!!, 0.0)
        // pausa longa recomeça a contagem
        assertEquals(null, t.tap(10_000_000_000L))
    }
}
