package com.pestana.estudio.core

/** Tipo de acorde (portado de Chords.swift). */
data class ChordQuality(
    val id: String,
    /** Como aparece no nome: "m", "7M", "m7(♭5)"… */
    val suffix: String,
    /** Nome por extenso. */
    val label: String,
    val intervals: List<Int>,
    val degrees: List<String>,
) {
    companion object {
        val all: List<ChordQuality> = listOf(
            ChordQuality("maj", "", "Maior", listOf(0, 4, 7), listOf("1", "3", "5")),
            ChordQuality("m", "m", "Menor", listOf(0, 3, 7), listOf("1", "♭3", "5")),
            ChordQuality("7", "7", "Sétima", listOf(0, 4, 7, 10), listOf("1", "3", "5", "♭7")),
            ChordQuality("m7", "m7", "Menor com sétima", listOf(0, 3, 7, 10), listOf("1", "♭3", "5", "♭7")),
            ChordQuality("maj7", "7M", "Sétima maior", listOf(0, 4, 7, 11), listOf("1", "3", "5", "7")),
            ChordQuality("6", "6", "Sexta", listOf(0, 4, 7, 9), listOf("1", "3", "5", "6")),
            ChordQuality("m6", "m6", "Menor com sexta", listOf(0, 3, 7, 9), listOf("1", "♭3", "5", "6")),
            ChordQuality("sus2", "sus2", "Suspenso 2", listOf(0, 2, 7), listOf("1", "2", "5")),
            ChordQuality("sus4", "sus4", "Suspenso 4", listOf(0, 5, 7), listOf("1", "4", "5")),
            ChordQuality("add9", "(9)", "Com nona", listOf(0, 4, 7, 2), listOf("1", "3", "5", "9")),
            ChordQuality("dim", "dim", "Diminuto", listOf(0, 3, 6), listOf("1", "♭3", "♭5")),
            ChordQuality("m7b5", "m7(♭5)", "Meio-diminuto", listOf(0, 3, 6, 10), listOf("1", "♭3", "♭5", "♭7")),
            ChordQuality("dim7", "°", "Diminuto com sétima", listOf(0, 3, 6, 9), listOf("1", "♭3", "♭5", "𝄫7")),
        )

        fun byId(id: String?): ChordQuality = all.firstOrNull { it.id == id } ?: all[0]
    }
}

/** Posição do acorde: casas da 6ª → 1ª corda (-1 = não tocar) e a casa da pestana, se houver. */
data class Voicing(val frets: List<Int>, val barre: Int?) {
    val lowestFret: Int get() = frets.filter { it > 0 }.minOrNull() ?: 0
    val highestFret: Int get() = frets.maxOrNull() ?: 0
}

object ChordBook {
    val rootNames = listOf("C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B")
    val solfege = listOf("Dó", "Dó♯", "Ré", "Mi♭", "Mi", "Fá", "Fá♯", "Sol", "Lá♭", "Lá", "Si♭", "Si")
    val openMidi = listOf(40, 45, 50, 55, 59, 64)

    // Formas móveis (deslocamento a partir da casa da pestana)
    private val eShape: Map<String, List<Int>> = mapOf(
        "maj" to listOf(0, 2, 2, 1, 0, 0), "m" to listOf(0, 2, 2, 0, 0, 0), "7" to listOf(0, 2, 0, 1, 0, 0),
        "m7" to listOf(0, 2, 0, 0, 0, 0), "maj7" to listOf(0, -1, 1, 1, 0, -1), "6" to listOf(0, 2, 2, 1, 2, 0),
        "sus4" to listOf(0, 2, 2, 2, 0, 0),
    )
    private val aShape: Map<String, List<Int>> = mapOf(
        "maj" to listOf(-1, 0, 2, 2, 2, 0), "m" to listOf(-1, 0, 2, 2, 1, 0), "7" to listOf(-1, 0, 2, 0, 2, 0),
        "m7" to listOf(-1, 0, 2, 0, 1, 0), "maj7" to listOf(-1, 0, 2, 1, 2, 0), "6" to listOf(-1, 0, 2, 2, 2, 2),
        "m6" to listOf(-1, 0, 2, 2, 1, 2), "sus2" to listOf(-1, 0, 2, 2, 0, 0), "sus4" to listOf(-1, 0, 2, 2, 3, 0),
        "add9" to listOf(-1, 0, 2, 4, 2, 0), "dim" to listOf(-1, 0, 1, 2, 1, -1), "m7b5" to listOf(-1, 0, 1, 0, 1, -1),
        "dim7" to listOf(-1, 0, 1, 2, 1, 2),
    )

    // Acordes abertos clássicos (fundamental 0 = C)
    private val open: Map<String, List<Int>> = mapOf(
        "0-maj" to listOf(-1, 3, 2, 0, 1, 0), "0-7" to listOf(-1, 3, 2, 3, 1, 0), "0-maj7" to listOf(-1, 3, 2, 0, 0, 0),
        "0-add9" to listOf(-1, 3, 2, 0, 3, 0), "0-sus4" to listOf(-1, 3, 3, 0, 1, 1),
        "2-maj" to listOf(-1, -1, 0, 2, 3, 2), "2-m" to listOf(-1, -1, 0, 2, 3, 1), "2-7" to listOf(-1, -1, 0, 2, 1, 2),
        "2-m7" to listOf(-1, -1, 0, 2, 1, 1), "2-maj7" to listOf(-1, -1, 0, 2, 2, 2), "2-sus2" to listOf(-1, -1, 0, 2, 3, 0),
        "2-sus4" to listOf(-1, -1, 0, 2, 3, 3), "2-6" to listOf(-1, -1, 0, 2, 0, 2), "2-dim" to listOf(-1, -1, 0, 1, 3, 1),
        "7-maj" to listOf(3, 2, 0, 0, 0, 3), "7-7" to listOf(3, 2, 0, 0, 0, 1), "7-maj7" to listOf(3, 2, 0, 0, 0, 2),
        "7-6" to listOf(3, 2, 0, 0, 0, 0), "7-sus4" to listOf(3, 3, 0, 0, 1, 3),
        "5-maj7" to listOf(-1, -1, 3, 2, 1, 0), "11-7" to listOf(-1, 2, 1, 2, 0, 2),
    )

    fun name(root: Int, quality: ChordQuality): String = rootNames[root] + quality.suffix

    fun notes(root: Int, quality: ChordQuality): List<String> =
        quality.intervals.map { rootNames[(root + it) % 12] }

    fun voicings(root: Int, quality: ChordQuality): List<Voicing> {
        val list = mutableListOf<Voicing>()
        open["$root-${quality.id}"]?.let { list.add(Voicing(it, null)) }
        eShape[quality.id]?.let { list.add(shift(it, (root - 4 + 12) % 12)) }
        aShape[quality.id]?.let { list.add(shift(it, (root - 9 + 12) % 12)) }
        val seen = HashSet<List<Int>>()
        val unique = list.filter { seen.add(it.frets) }
        return unique.sortedWith(
            compareBy<Voicing> { if (it.barre == null) 0 else 1 }.thenBy { it.lowestFret },
        )
    }

    private fun shift(shape: List<Int>, f: Int): Voicing =
        Voicing(shape.map { if (it < 0) -1 else it + f }, if (f > 0) f else null)

    fun midiNotes(v: Voicing): List<Int> =
        v.frets.mapIndexedNotNull { i, f -> if (f >= 0) openMidi[i] + f else null }
}
