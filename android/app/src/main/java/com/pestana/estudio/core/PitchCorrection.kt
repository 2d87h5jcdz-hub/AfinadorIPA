package com.pestana.estudio.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Afinação automática da voz (correção sutil, feita depois de gravar) — porte fiel do
 * StudioPitchCorrection.swift do iOS:
 * 1. Nota cantada a cada ~5 ms (YIN numa cópia reduzida para ~11–12 kHz).
 * 2. Limpeza: saltos de oitava, mediana, descarta trechos curtíssimos.
 * 3. Divide em notas (curva suavizada ~180 ms → nota da escala mais próxima).
 * 4. Um desvio por nota (× intensidade): vibrato e expressão ficam; só o centro vai para o lugar.
 * 5. Rampa de ~45 ms e mudança de tom por TD-PSOLA. Sem voz, o áudio passa igual.
 */
enum class PitchScale(val key: String, val title: String, val intervals: List<Int>) {
    MAJOR("major", "Maior", listOf(0, 2, 4, 5, 7, 9, 11)),
    MINOR("minor", "Menor", listOf(0, 2, 3, 5, 7, 8, 10)),
    CHROMATIC("chromatic", "Cromática", (0 until 12).toList());

    companion object {
        fun byKey(k: String?) = entries.firstOrNull { it.key == k } ?: MAJOR
    }
}

data class PitchSettings(
    val enabled: Boolean = false,
    /** 0…11 = Dó…Si; -1 = automático (detectado pela voz). */
    val key: Int = -1,
    val scale: PitchScale = PitchScale.MAJOR,
    /** 0…1: quanto do desvio é corrigido (0,8 deixa um resíduo que soa humano). */
    val strength: Float = 0.8f,
    val detectedKey: Int? = null,
    val detectedScale: PitchScale? = null,
) {
    val isAuto get() = key < 0
    val resolvedKey: Int? get() = if (key >= 0) key else detectedKey
    val resolvedScale: PitchScale get() = if (key >= 0) scale else detectedScale ?: PitchScale.MAJOR

    /** Identifica o resultado (vai no nome do arquivo corrigido). null = desligado ou tom desconhecido. */
    val signature: String?
        get() {
            if (!enabled) return null
            val k = resolvedKey ?: return null
            val pct = (strength.coerceIn(0f, 1f) * 100).roundToInt()
            return "$k${resolvedScale.key.take(3)}$pct"
        }

    companion object {
        val noteNames = listOf("Dó", "Dó♯", "Ré", "Mi♭", "Mi", "Fá", "Fá♯", "Sol", "Lá♭", "Lá", "Si♭", "Si")
        fun keyTitle(key: Int, scale: PitchScale): String {
            val name = noteNames[((key % 12) + 12) % 12]
            return when (scale) {
                PitchScale.MAJOR -> "$name maior"
                PitchScale.MINOR -> "$name menor"
                PitchScale.CHROMATIC -> "cromática"
            }
        }
    }
}

object PitchDsp {
    class Analysis(
        /** Nota MIDI (fracionária) por quadro; NaN = sem voz. */
        val midi: FloatArray,
        /** Passo entre quadros, em amostras originais. */
        val hop: Int,
        /** Atraso do centro da janela de análise, em amostras originais. */
        val center: Int,
    )

    private fun lowpass(taps: Int, cutoff: Float): FloatArray {
        val h = FloatArray(taps)
        val mid = (taps - 1) / 2f
        var sum = 0f
        for (n in 0 until taps) {
            val x = n - mid
            val sinc = if (x == 0f) 1f else (sin(PI * cutoff * x) / (PI * cutoff * x)).toFloat()
            val window = (0.54 - 0.46 * cos(2 * PI * n / (taps - 1))).toFloat()
            h[n] = cutoff * sinc * window
            sum += h[n]
        }
        if (sum != 0f) for (n in 0 until taps) h[n] /= sum
        return h
    }

    fun analyze(mono: FloatArray, sampleRate: Double): Analysis {
        val factor = max(1, (sampleRate / 11025).roundToInt())
        val taps = 63
        val y: FloatArray
        if (factor > 1) {
            val n = (mono.size - taps) / factor
            if (n <= 0) return Analysis(FloatArray(0), 1, 0)
            val h = lowpass(taps, 0.8f / factor)
            // vDSP_desamp: y[k] = Σ x[k·factor + j]·h[j]
            y = FloatArray(n) { k ->
                var s = 0f
                val base = k * factor
                for (j in 0 until taps) s += mono[base + j] * h[j]
                s
            }
        } else {
            y = mono
        }
        val asr = sampleRate / factor
        val window = max(16, (asr * 0.027).toInt())
        val tauMax = (asr / 70).toInt() + 1
        val tauMin = max(2, (asr / 1000).toInt())
        val hop = max(1, (asr * 0.005).roundToInt())
        val center = (window / 2) * factor + if (factor > 1) (taps - 1) / 2 else 0
        var peak = 0f
        for (v in mono) peak = max(peak, abs(v))
        val gate = max(peak, 1e-9f) * 0.02f
        if (y.size <= window + tauMax + 1) return Analysis(FloatArray(0), hop * factor, center)

        val cs = DoubleArray(y.size + 1)
        for (i in y.indices) cs[i + 1] = cs[i] + (y[i] * y[i]).toDouble()
        val out = ArrayList<Float>(y.size / hop + 1)
        val d = FloatArray(tauMax + 2)
        val cm = FloatArray(tauMax + 2) { 1f }
        var i = 0
        while (i + window + tauMax <= y.size) {
            val e0 = (cs[i + window] - cs[i]).toFloat()
            val rms = sqrt(max(e0, 0f) / window)
            if (rms <= gate) {
                out.add(Float.NaN); i += hop; continue
            }
            for (tau in 1..tauMax) {
                val et = (cs[i + tau + window] - cs[i + tau]).toFloat()
                var r = 0f
                for (k in 0 until window) r += y[i + k] * y[i + tau + k]
                d[tau] = e0 + et - 2 * r
            }
            var running = 0f
            cm[0] = 1f
            for (tau in 1..tauMax) {
                running += d[tau]
                cm[tau] = if (running > 0) d[tau] * tau / running else 1f
            }
            var best = -1
            var tau = tauMin
            while (tau <= tauMax) {
                if (cm[tau] < 0.15f) {
                    while (tau + 1 <= tauMax && cm[tau + 1] < cm[tau]) tau++
                    best = tau
                    break
                }
                tau++
            }
            if (best < 0) {
                var minV = Float.MAX_VALUE
                for (t in tauMin..tauMax) if (cm[t] < minV) { minV = cm[t]; best = t }
            }
            val aperiodicity = cm[best]
            var period = best.toFloat()
            if (best >= 1 && best < tauMax) {
                val s0 = cm[best - 1]; val s1 = cm[best]; val s2 = cm[best + 1]
                val den = s0 - 2 * s1 + s2
                if (abs(den) > 1e-12f) period = best + 0.5f * (s0 - s2) / den
            }
            val f0 = (asr / max(period, 1f)).toFloat()
            if (aperiodicity < 0.25f && f0 in 70f..1000f) out.add((69 + 12 * ln(f0 / 440.0) / ln(2.0)).toFloat())
            else out.add(Float.NaN)
            i += hop
        }
        return Analysis(clean(out.toFloatArray()), hop * factor, center)
    }

    private fun median(values: MutableList<Float>): Float {
        if (values.isEmpty()) return Float.NaN
        values.sort()
        val c = values.size
        return if (c % 2 == 1) values[c / 2] else 0.5f * (values[c / 2 - 1] + values[c / 2])
    }

    /** Saltos de oitava, mediana de 5 e remoção de trechos com voz curtos demais (< 7 quadros). */
    fun clean(input: FloatArray): FloatArray {
        val n = input.size
        val m = input.copyOf()
        if (n == 0) return m
        for (i in 0 until n) {
            if (m[i].isNaN()) continue
            val w = ArrayList<Float>(41)
            for (j in max(0, i - 20) until min(n, i + 21)) if (!input[j].isNaN()) w.add(input[j])
            if (w.size < 5) continue
            val med = median(w)
            while (m[i] - med > 9) m[i] -= 12f
            while (med - m[i] > 9) m[i] += 12f
        }
        val out = m.copyOf()
        for (i in 0 until n) {
            if (m[i].isNaN()) continue
            val w = ArrayList<Float>(5)
            for (j in max(0, i - 2) until min(n, i + 3)) if (!m[j].isNaN()) w.add(m[j])
            out[i] = median(w)
        }
        var i = 0
        while (i < n) {
            if (out[i].isNaN()) { i++; continue }
            var j = i
            while (j < n && !out[j].isNaN()) j++
            if (j - i < 7) for (k in i until j) out[k] = Float.NaN
            i = j
        }
        return out
    }

    private val majorProfile = floatArrayOf(6.35f, 2.23f, 3.48f, 2.33f, 4.38f, 4.09f, 2.52f, 5.19f, 2.39f, 3.66f, 2.29f, 2.88f)
    private val minorProfile = floatArrayOf(6.33f, 2.68f, 3.52f, 5.38f, 2.60f, 3.53f, 2.54f, 4.75f, 3.98f, 2.69f, 3.34f, 3.17f)

    /** Tom da música pelo histograma das notas cantadas (Krumhansl-Schmuckler). */
    fun detectKey(midi: FloatArray): Pair<Int, PitchScale>? {
        val hist = FloatArray(12)
        var voiced = 0
        for (v in midi) if (!v.isNaN()) {
            hist[((v.roundToInt() % 12) + 12) % 12] += 1f
            voiced++
        }
        if (voiced < 40) return null
        var best: Triple<Float, Int, PitchScale>? = null
        for (key in 0 until 12) {
            for ((profile, scale) in listOf(majorProfile to PitchScale.MAJOR, minorProfile to PitchScale.MINOR)) {
                val rot = FloatArray(12)
                for (i in 0 until 12) rot[(i + key) % 12] = profile[i]
                val score = correlation(hist, rot)
                if (best == null || score > best.first) best = Triple(score, key, scale)
            }
        }
        return best?.let { it.second to it.third }
    }

    private fun correlation(a: FloatArray, b: FloatArray): Float {
        val ma = a.average().toFloat(); val mb = b.average().toFloat()
        var num = 0f; var da = 0f; var db = 0f
        for (i in a.indices) {
            val x = a[i] - ma; val y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        val den = sqrt(da * db)
        return if (den > 0) num / den else 0f
    }

    /** Nota da escala mais próxima de [v] (MIDI fracionário). */
    fun quantize(v: Float, key: Int, scale: PitchScale): Float {
        val classes = scale.intervals.map { (key + it) % 12 }.toSet()
        val base = floor(v)
        var best: Pair<Float, Float>? = null
        for (o in -2..2) {
            val cand = base + o
            val pc = ((cand.toInt() % 12) + 12) % 12
            if (pc !in classes) continue
            val dist = abs(cand - v)
            if (best == null || dist < best.first) best = dist to cand
        }
        return best?.second ?: v.roundToInt().toFloat()
    }

    /** Correção em semitons por quadro (0 sem voz), já suavizada nas trocas de nota. */
    fun correction(m: FloatArray, key: Int, scale: PitchScale, strength: Float): FloatArray {
        val n = m.size
        val c = FloatArray(n)
        val amount = strength.coerceIn(0f, 1f)
        var i = 0
        while (i < n) {
            if (m[i].isNaN()) { i++; continue }
            var j = i
            while (j < n && !m[j].isNaN()) j++
            val length = j - i
            val prefix = FloatArray(length + 1)
            for (t in 0 until length) prefix[t + 1] = prefix[t] + m[i + t]
            val notes = FloatArray(length) { t ->
                val lo = max(0, t - 18); val hi = min(length, t + 19)
                quantize((prefix[hi] - prefix[lo]) / (hi - lo), key, scale)
            }
            val segments = ArrayList<IntArray>()
            var start = 0
            for (t in 1..length) {
                if (t == length || notes[t] != notes[start]) {
                    segments.add(intArrayOf(start, t)); start = t
                }
            }
            val merged = ArrayList<IntArray>()
            for (seg in segments) {
                if (merged.isNotEmpty() && seg[1] - seg[0] < 12) merged.last()[1] = seg[1]
                else merged.add(seg.copyOf())
            }
            if (merged.size > 1 && merged[0][1] - merged[0][0] < 12) {
                merged[1][0] = merged[0][0]
                merged.removeAt(0)
            }
            for (seg in merged) {
                val values = ArrayList<Float>(seg[1] - seg[0])
                for (t in seg[0] until seg[1]) values.add(m[i + t])
                val center = median(values)
                val target = quantize(center, key, scale)
                var offset = target - center
                if (abs(offset) < 0.04f) offset = 0f
                for (t in seg[0] until seg[1]) c[i + t] = offset * amount
            }
            i = j
        }
        val prefix = FloatArray(n + 1)
        for (t in 0 until n) prefix[t + 1] = prefix[t] + c[t]
        return FloatArray(n) { t ->
            val lo = max(0, t - 4); val hi = min(n, t + 5)
            (prefix[hi] - prefix[lo]) / (hi - lo)
        }
    }

    /** Mudança de tom por TD-PSOLA (grãos de 2 períodos, Hann, normalizado pela soma das janelas). */
    fun psola(channels: Array<FloatArray>, sampleRate: Double, analysis: Analysis, ratio: FloatArray): Array<FloatArray> {
        val length = channels.firstOrNull()?.size ?: return channels
        val frames = analysis.midi.size
        if (length == 0 || frames == 0) return channels
        val hop = max(analysis.hop, 1).toDouble()
        val center = analysis.center.toDouble()
        fun frameIndex(p: Double) = floor((p - center) / hop).toInt().coerceIn(0, frames - 1)
        val unvoiced = sampleRate * 0.006
        fun period(p: Double): Double {
            val m = analysis.midi[frameIndex(p)]
            if (m.isNaN()) return unvoiced
            val f0 = 440 * 2.0.pow((m - 69) / 12.0)
            return (sampleRate / f0).coerceIn(8.0, sampleRate * 0.02)
        }
        fun ratioAt(p: Double): Double {
            val r = ratio[frameIndex(p)].toDouble()
            return if (r.isFinite() && r > 0.5 && r < 2) r else 1.0
        }
        val marks = ArrayList<Double>(length / 100)
        var p = 0.0
        while (p < length) { marks.add(p); p += period(p) }

        val out = Array(channels.size) { FloatArray(length) }
        val weights = FloatArray(length)
        var ts = 0.0
        var k = 0
        var window = FloatArray(0)
        while (ts < length) {
            while (k + 1 < marks.size && abs(marks[k + 1] - ts) < abs(marks[k] - ts)) k++
            val a = marks[k]
            val T = period(a)
            val r = ratioAt(ts)
            val half = floor(T).toInt()
            val count = 2 * half + 1
            if (window.size != count) window = FloatArray(count)
            for (idx in 0 until count) window[idx] = (0.5 * (1 + cos(PI * (idx - half) / T))).toFloat()
            val srcBase = Math.round(a).toInt() - half
            val dstBase = Math.round(ts).toInt() - half
            val lo = max(0, max(-srcBase, -dstBase))
            val hi = min(count, min(length - srcBase, length - dstBase))
            if (lo < hi) {
                for (idx in lo until hi) weights[dstBase + idx] += window[idx]
                for (ch in channels.indices) {
                    val src = channels[ch]; val dst = out[ch]
                    for (idx in lo until hi) dst[dstBase + idx] += src[srcBase + idx] * window[idx]
                }
            }
            ts += T / r
        }
        for (ch in out.indices) {
            val dst = out[ch]
            for (i in 0 until length) { val w = weights[i]; if (w > 1e-3f) dst[i] /= w }
        }
        return out
    }

    /** Afina um áudio inteiro (canais planos). Devolve os canais corrigidos. */
    fun process(channels: Array<FloatArray>, sampleRate: Double, key: Int, scale: PitchScale, strength: Float, cached: Analysis? = null): Array<FloatArray> {
        val n = channels[0].size
        val mono = FloatArray(n) { i -> var s = 0f; for (c in channels) s += c[i]; s / channels.size }
        val analysis = cached ?: analyze(mono, sampleRate)
        val curve = correction(analysis.midi, key, scale, strength)
        val ratio = FloatArray(curve.size) { 2.0.pow(curve[it] / 12.0).toFloat() }
        return psola(channels, sampleRate, analysis, ratio)
    }
}
