package com.pestana.estudio.core

import kotlin.math.abs
import kotlin.math.roundToInt

/** Uma leitura do afinador, pronta para a interface. */
data class TunerReading(
    val frequency: Double,
    val targetMidi: Int,
    val cents: Int,
    /** Cents sem arredondar, para o ponteiro se mover de forma contínua. */
    val centsPrecise: Double,
    val stringIndex: Int?,
)

/**
 * Lógica do afinador sem dependência de Android (portada do TunerEngine.swift):
 * mediana das últimas leituras, escolha da corda (automático ou por corda) e cents.
 */
class TunerLogic {
    private val history = ArrayDeque<Double>()
    private var silentFrames = 0

    /** @return a leitura nova; null = silêncio prolongado (limpar o mostrador); Unchanged = manter. */
    fun feed(
        f: Double?,
        tuning: Tuning,
        a4: Double,
        autoMode: Boolean,
        manualIndex: Int,
    ): Result {
        if (f == null || f <= 60 || f >= 1200) {
            silentFrames++
            if (silentFrames > 6) {
                history.clear()
                return Result.Clear
            }
            return Result.Unchanged
        }
        silentFrames = 0
        history.addLast(f)
        if (history.size > 5) history.removeFirst()
        val median = history.sorted()[history.size / 2]
        return Result.Reading(read(median, tuning, a4, autoMode, manualIndex))
    }

    fun reset() {
        history.clear()
        silentFrames = 0
    }

    sealed interface Result {
        data object Unchanged : Result
        data object Clear : Result
        data class Reading(val reading: TunerReading) : Result
    }

    companion object {
        fun read(f: Double, tuning: Tuning, a4: Double, autoMode: Boolean, manualIndex: Int): TunerReading {
            val notes = tuning.midi
            val m = Pitch.midi(f, a4)
            var target: Int
            val idx: Int?
            if (autoMode) {
                var best = Double.POSITIVE_INFINITY
                var bestIdx = 0
                notes.forEachIndexed { i, n ->
                    val d = abs(m - n)
                    if (d < best) {
                        best = d; bestIdx = i
                    }
                }
                if (best <= 2.5) {
                    target = notes[bestIdx]; idx = bestIdx
                } else {
                    target = m.roundToInt(); idx = null
                }
            } else {
                val i = manualIndex.coerceIn(0, notes.size - 1)
                idx = i
                target = notes[i]
                while (m - target > 6) target += 12
                while (target - m > 6) target -= 12
            }
            val precise = (m - target) * 100
            return TunerReading(f, target, precise.roundToInt(), precise, idx)
        }
    }
}

/**
 * Ponteiro com "mola": persegue a leitura com amortecimento crítico, quadro a quadro,
 * como o ponteiro físico de um afinador (sem trancos e sem passar do ponto).
 */
class NeedleSpring(private val omega: Double = 14.0) {
    var value = 0.0
        private set
    private var velocity = 0.0
    private var lastNanos = -1L

    fun step(target: Double, frameNanos: Long): Double {
        val dt = if (lastNanos < 0) 0.0 else ((frameNanos - lastNanos) / 1e9).coerceIn(0.0, 1.0 / 30.0)
        lastNanos = frameNanos
        // x'' = ω²(alvo − x) − 2ωx'  (amortecimento crítico)
        val accel = omega * omega * (target - value) - 2 * omega * velocity
        velocity += accel * dt
        value += velocity * dt
        return value
    }
}
