package com.pestana.estudio.core

import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.pow

/** Afinação do violão: notas MIDI da 6ª corda → 1ª corda. */
data class Tuning(val name: String, val midi: List<Int>) {
    companion object {
        val all: List<Tuning> = listOf(
            Tuning("Padrão (E A D G B E)", listOf(40, 45, 50, 55, 59, 64)),
            Tuning("Drop D (D A D G B E)", listOf(38, 45, 50, 55, 59, 64)),
            Tuning("Meio tom abaixo (E♭)", listOf(39, 44, 49, 54, 58, 63)),
            Tuning("Um tom abaixo (D G C F A D)", listOf(38, 43, 48, 53, 57, 62)),
            Tuning("Open G (D G D G B D)", listOf(38, 43, 50, 55, 59, 62)),
            Tuning("DADGAD", listOf(38, 45, 50, 55, 57, 62)),
        )

        fun byName(name: String?): Tuning = all.firstOrNull { it.name == name } ?: all[0]
    }
}

object Note {
    val names = listOf("C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B")
    fun name(midi: Int): String = names[((midi % 12) + 12) % 12]
    fun octave(midi: Int): Int = floor(midi / 12.0).toInt() - 1
}

/** Lá central (A4): 415–466 Hz, padrão 440. */
object Pitch {
    const val A4_MIN = 415.0
    const val A4_MAX = 466.0
    const val A4_DEFAULT = 440.0

    fun hz(midi: Int, a4: Double): Double = a4 * 2.0.pow((midi - 69) / 12.0)
    fun hz(midi: Double, a4: Double): Double = a4 * 2.0.pow((midi - 69) / 12.0)
    fun midi(freq: Double, a4: Double): Double = 69 + 12 * (ln(freq / a4) / ln(2.0))
}
