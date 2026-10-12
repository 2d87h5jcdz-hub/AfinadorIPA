package com.pestana.estudio.core

import kotlin.math.sqrt

/** Detector de frequência fundamental YIN (mesmo algoritmo e limiares do app iOS). */
object Yin {
    /**
     * @param x janela de áudio (o iOS usa 4096 amostras)
     * @return frequência em Hz, ou null se houver silêncio/sinal sem altura definida.
     */
    fun detect(x: FloatArray, sampleRate: Double, scratch: FloatArray? = null): Double? {
        var rms = 0f
        for (v in x) rms += v * v
        rms = sqrt(rms / x.size)
        if (rms < 0.006f) return null

        val w = x.size / 2
        val minTau = (sampleRate / 1000).toInt()
        val maxTau = minOf((sampleRate / 60).toInt(), w - 1)
        val d = if (scratch != null && scratch.size >= maxTau + 2) scratch else FloatArray(maxTau + 2)

        for (tau in 1..maxTau) {
            var s = 0f
            var i = 0
            while (i < w) {
                val v = x[i] - x[i + tau]
                s += v * v
                i++
            }
            d[tau] = s
        }
        d[0] = 1f
        var running = 0f
        for (t in 1..maxTau) {
            running += d[t]
            d[t] = if (running > 0) d[t] * t / running else 1f
        }

        var tau = -1
        var t = minTau
        while (t <= maxTau) {
            if (d[t] < 0.12f) {
                while (t + 1 <= maxTau && d[t + 1] < d[t]) t++
                tau = t
                break
            }
            t++
        }
        if (tau <= 1 || tau >= maxTau) return null

        val a = d[tau - 1].toDouble()
        val b = d[tau].toDouble()
        val c = d[tau + 1].toDouble()
        val denom = a - 2 * b + c
        val shift = if (denom != 0.0) (a - c) / (2 * denom) else 0.0
        return sampleRate / (tau + if (shift.isFinite()) shift else 0.0)
    }
}
