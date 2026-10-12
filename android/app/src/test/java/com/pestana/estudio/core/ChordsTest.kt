package com.pestana.estudio.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChordsTest {
    @Test
    fun cMajorStartsWithOpenShape() {
        val v = ChordBook.voicings(0, ChordQuality.byId("maj"))
        assertEquals(listOf(-1, 3, 2, 0, 1, 0), v.first().frets)
        assertEquals(null, v.first().barre)
        assertEquals(3, v.size)
        assertEquals(listOf(-1, 3, 5, 5, 5, 3), v[1].frets) // forma de Lá na 3ª
        assertEquals(listOf(8, 10, 10, 9, 8, 8), v[2].frets) // forma de Mi na 8ª
    }

    @Test
    fun everyChordHasAtLeastOnePosition() {
        for (root in 0 until 12) for (q in ChordQuality.all) {
            val v = ChordBook.voicings(root, q)
            assertTrue("${ChordBook.name(root, q)} sem posição", v.isNotEmpty())
            for (p in v) assertEquals(6, p.frets.size)
        }
    }

    @Test
    fun voicingNotesBelongToChord() {
        for (root in 0 until 12) for (q in ChordQuality.all) {
            val pcs = q.intervals.map { (root + it) % 12 }.toSet()
            for (v in ChordBook.voicings(root, q)) for (m in ChordBook.midiNotes(v)) {
                assertTrue("${ChordBook.name(root, q)} ${v.frets}: nota $m fora do acorde", (m % 12) in pcs)
            }
        }
    }

    @Test
    fun names() {
        assertEquals("F♯m7(♭5)", ChordBook.name(6, ChordQuality.byId("m7b5")))
        assertEquals(listOf("A", "C", "E"), ChordBook.notes(9, ChordQuality.byId("m")))
    }
}
