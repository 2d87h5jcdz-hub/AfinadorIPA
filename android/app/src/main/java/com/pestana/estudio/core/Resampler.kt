package com.pestana.estudio.core

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.sin

/**
 * Reamostragem estéreo por sinc janelado (Blackman), com tabela polifásica interpolada.
 * Streaming: aceita blocos de qualquer tamanho; [finish] devolve o rabo final.
 * Usado para levar qualquer música (48 kHz, 32 kHz…) a 44,1 kHz, a taxa do Demucs.
 */
class Resampler(private val inRate: Int, private val outRate: Int) {
    private val half = 16 // taps de cada lado
    private val phases = 256
    private val ratio = inRate.toDouble() / outRate // passo na entrada por amostra de saída
    private val cutoff = min(1.0, outRate.toDouble() / inRate) * 0.97
    private val table: Array<FloatArray>
    val passthrough = inRate == outRate

    // histórico de entrada (estéreo planar)
    private var bufL = FloatArray(8192)
    private var bufR = FloatArray(8192)
    private var len = 0
    /** posição (em amostras de entrada, relativa a bufL[0]) da próxima saída */
    private var pos = 0.0
    private var started = false

    init {
        table = Array(phases + 1) { p ->
            val frac = p.toDouble() / phases
            FloatArray(2 * half) { k ->
                val x = (k - half + 1) - frac // distância da amostra k ao ponto
                val sinc = if (x == 0.0) 1.0 else sin(PI * cutoff * x) / (PI * cutoff * x)
                val wpos = (x + half) / (2 * half) // 0…1
                val win = if (wpos <= 0 || wpos >= 1) 0.0 else 0.42 - 0.5 * cos(2 * PI * wpos) + 0.08 * cos(4 * PI * wpos)
                (sinc * win * cutoff).toFloat()
            }
        }
    }

    private fun append(l: FloatArray, r: FloatArray, n: Int) {
        if (len + n > bufL.size) {
            val cap = maxOf(bufL.size * 2, len + n)
            bufL = bufL.copyOf(cap); bufR = bufR.copyOf(cap)
        }
        System.arraycopy(l, 0, bufL, len, n)
        System.arraycopy(r, 0, bufR, len, n)
        len += n
    }

    /** Processa [n] quadros; o resultado vai para [outL]/[outR] (redimensionados se preciso). */
    fun process(l: FloatArray, r: FloatArray, n: Int, sink: (FloatArray, FloatArray, Int) -> Unit) {
        if (passthrough) {
            sink(l, r, n); return
        }
        if (!started) {
            // começa com "half" zeros à esquerda: a primeira saída corresponde à 1ª entrada
            val z = FloatArray(half - 1)
            append(z, z, z.size)
            pos = (half - 1).toDouble()
            started = true
        }
        append(l, r, n)
        drain(sink, final = false)
    }

    fun finish(sink: (FloatArray, FloatArray, Int) -> Unit) {
        if (passthrough || !started) return
        val z = FloatArray(half + 1)
        append(z, z, z.size)
        drain(sink, final = true)
    }

    private var oL = FloatArray(4096)
    private var oR = FloatArray(4096)

    private fun drain(sink: (FloatArray, FloatArray, Int) -> Unit, final: Boolean) {
        val limit = len - half // precisa de half amostras à direita
        val est = ((limit - pos) / ratio).toInt() + 2
        if (est > oL.size) { oL = FloatArray(est); oR = FloatArray(est) }
        var k = 0
        while (pos < limit - (if (final) 1 else 0)) {
            val ip = floor(pos).toInt()
            val frac = pos - ip
            val fp = frac * phases
            val p0 = fp.toInt()
            val t = (fp - p0).toFloat()
            val c0 = table[p0]; val c1 = table[p0 + 1]
            var sl = 0f; var sr = 0f
            val base = ip - half + 1
            for (j in 0 until 2 * half) {
                val c = c0[j] + (c1[j] - c0[j]) * t
                sl += bufL[base + j] * c
                sr += bufR[base + j] * c
            }
            oL[k] = sl; oR[k] = sr; k++
            pos += ratio
        }
        if (k > 0) sink(oL, oR, k)
        // descarta o que não será mais usado
        val drop = floor(pos).toInt() - half
        if (drop > 0) {
            System.arraycopy(bufL, drop, bufL, 0, len - drop)
            System.arraycopy(bufR, drop, bufR, 0, len - drop)
            len -= drop
            pos -= drop
        }
    }
}
