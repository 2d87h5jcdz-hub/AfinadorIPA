package com.pestana.estudio.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.sin
import kotlin.random.Random

class DspTest {
    @Test
    fun fftMatchesNaiveDft() {
        val n = 64
        val fft = Fft(n)
        val rnd = Random(3)
        val x = DoubleArray(n) { rnd.nextDouble(-1.0, 1.0) }
        val re = x.copyOf(); val im = DoubleArray(n)
        fft.transform(re, im)
        for (k in 0 until n) {
            var r = 0.0; var i = 0.0
            for (t in 0 until n) { r += x[t] * kotlin.math.cos(2 * PI * k * t / n); i -= x[t] * sin(2 * PI * k * t / n) }
            assertEquals(r, re[k], 1e-9); assertEquals(i, im[k], 1e-9)
        }
    }

    /**
     * Com um "modelo" linear (fonte s = a_s·espectro + b_s·forma de onda, a+b = 1) a soma de
     * STFT → iSTFT → overlap-add precisa devolver a mixagem original (a menos do bin de Nyquist,
     * que o HTDemucs descarta de propósito — por isso ~30 dB e não 100+): valida a cadeia inteira.
     * (A mesma cadeia foi comparada amostra a amostra com o numpy do convert_demucs.py: 143 dB.)
     */
    @Test
    fun separationChainReconstructsMix() {
        val L = 12000; val n = 40001
        val dsp = DemucsDsp(L, 2)
        val rnd = Random(9)
        val mixL = FloatArray(n) { (0.3 * sin(2 * PI * 220 * it / 44100.0) + 0.05 * rnd.nextDouble(-1.0, 1.0)).toFloat() }
        val mixR = FloatArray(n) { (0.25 * sin(2 * PI * 330 * it / 44100.0) + 0.1).toFloat() }
        val mono = DoubleArray(n) { (mixL[it] + mixR[it]) / 2.0 }
        val mean = mono.average()
        val std = kotlin.math.sqrt(mono.sumOf { (it - mean) * (it - mean) } / (n - 1))
        val a = floatArrayOf(0.7f, 0.2f)
        val out = Array(2) { Array(2) { FloatArray(n) } }
        var w = 0
        dsp.separate(
            n.toLong(), mean, std,
            { start, count, l, r ->
                System.arraycopy(mixL, start.toInt(), l, 0, count)
                System.arraycopy(mixR, start.toInt(), r, 0, count)
            },
            { mag, mix, spec, time ->
                for (s in 0 until 2) {
                    for (k in 0 until dsp.magSize) spec.put(s * dsp.magSize + k, mag.get(k) * a[s])
                    for (k in 0 until dsp.mixSize) time.put(s * dsp.mixSize + k, mix.get(k) * (1 - a[s]))
                }
            },
            { data, count ->
                for (s in 0 until 2) for (c in 0 until 2) System.arraycopy(data[s][c], 0, out[s][c], w, count)
                w += count
            },
        )
        assertEquals(n, w)
        for (s in 0 until 2) {
            var err = 0.0; var pw = 0.0
            for (i in 0 until n) {
                err += (out[s][0][i] - mixL[i]).let { it * it } + (out[s][1][i] - mixR[i]).let { it * it }
                pw += mixL[i] * mixL[i] + mixR[i] * mixR[i]
            }
            val snr = 10 * log10(pw / err)
            assertTrue("fonte $s: SNR $snr", snr > 25)
        }
    }

    @Test
    fun resamplerKeepsPitchAndLength() {
        for ((inRate, outRate) in listOf(48000 to 44100, 22050 to 44100, 44100 to 44100)) {
            val r = Resampler(inRate, outRate)
            val f = 440.0
            val n = inRate * 2
            val src = FloatArray(n) { (0.5 * sin(2 * PI * f * it / inRate)).toFloat() }
            val out = ArrayList<Float>()
            var i = 0
            while (i < n) {
                val k = minOf(1000, n - i)
                val l = src.copyOfRange(i, i + k)
                r.process(l, l, k) { ol, _, c -> for (j in 0 until c) out.add(ol[j]) }
                i += k
            }
            r.finish { ol, _, c -> for (j in 0 until c) out.add(ol[j]) }
            val expected = n.toLong() * outRate / inRate
            assertTrue("$inRate→$outRate: ${out.size} vs $expected", abs(out.size - expected) <= 2)
            // compara com o seno ideal na taxa nova (longe das bordas)
            var err = 0.0; var pw = 0.0
            for (j in 2000 until out.size - 2000) {
                val ideal = 0.5 * sin(2 * PI * f * j / outRate)
                err += (out[j] - ideal) * (out[j] - ideal); pw += ideal * ideal
            }
            val snr = 10 * log10(pw / err)
            assertTrue("$inRate→$outRate SNR $snr", snr > 60)
        }
    }
}
