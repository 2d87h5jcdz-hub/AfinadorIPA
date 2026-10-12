package com.pestana.estudio.core

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * DSP do separador (contrato "afinador-demucs-v1"), espelho exato de host_stft/host_istft/
 * host_separate em scripts/convert_demucs.py e do DemucsSeparator.swift do iOS:
 * STFT n_fft 4096 / hop 1024 / Hann periódica / normalização 1/sqrt(n_fft) fora do modelo;
 * segmentos com 25 % de sobreposição, janela triangular e acumulador rolante.
 *
 * Layout dos tensores (row-major, como o ONNX):
 *   mag      (1, 4, 2048, T)    [esq_re, esq_im, dir_re, dir_im]
 *   mix      (1, 2, L)
 *   spec_out (1, S, 4, 2048, T)
 *   time_out (1, S, 2, L)
 */
class DemucsDsp(val segment: Int, val sources: Int) {
    companion object {
        const val SAMPLE_RATE = 44_100
        const val NFFT = 4096
        const val HOP = 1024
        const val BINS = NFFT / 2
        const val OVERLAP = 0.25

        fun framesFor(length: Int) = (length + HOP - 1) / HOP
    }

    val frames = framesFor(segment)
    val magSize = 4 * BINS * frames
    val mixSize = 2 * segment
    val specOutSize = sources * magSize
    val timeOutSize = sources * mixSize

    private val fft = Fft(NFFT)
    private val win = DoubleArray(NFFT) { 0.5 - 0.5 * cos(2 * PI * it / NFFT) }
    private val norm = 1.0 / sqrt(NFFT.toDouble())
    private val re = DoubleArray(NFFT)
    private val im = DoubleArray(NFFT)

    // Envelope do iSTFT (soma das janelas²), igual para todo segmento de tamanho L.
    private val istftStart = NFFT / 2 + HOP / 2 * 3
    private val invEnv: DoubleArray = run {
        val total = frames + 4
        val env = DoubleArray((total - 1) * HOP + NFFT)
        for (f in 0 until total) for (i in 0 until NFFT) env[f * HOP + i] += win[i] * win[i]
        DoubleArray(segment) { 1.0 / env[istftStart + it] }
    }
    private val olaBuf = DoubleArray((frames + 3) * HOP + NFFT)

    /** seg: (2, L) planar → mag (4, 2048, T). */
    fun stft(seg: FloatArray, mag: FloatArray) {
        val pad = HOP / 2 * 3
        for (c in 0 until 2) {
            val base = c * segment
            for (t in 0 until frames) {
                for (i in 0 until NFFT) {
                    // índice no sinal com padding "reflect" (sem repetir a borda)
                    var k = t * HOP + i - pad
                    if (k < 0) k = -k
                    if (k >= segment) k = 2 * (segment - 1) - k
                    if (k < 0) k = 0 // segmentos minúsculos (não ocorre com L real)
                    re[i] = seg[base + k] * win[i]
                    im[i] = 0.0
                }
                fft.transform(re, im)
                val reBase = (2 * c) * BINS * frames
                val imBase = (2 * c + 1) * BINS * frames
                for (f in 0 until BINS) {
                    mag[reBase + f * frames + t] = (re[f] * norm).toFloat()
                    mag[imBase + f * frames + t] = (im[f] * norm).toFloat()
                }
            }
        }
    }

    /**
     * Soma em [out] (tamanho L, a partir de outOff) o iSTFT do espectrograma em [spec]:
     * parte real em reOff e imaginária em imOff, cada uma (2048, T).
     */
    fun istftAdd(spec: FloatArray, reOff: Int, imOff: Int, out: DoubleArray) {
        java.util.Arrays.fill(olaBuf, 0.0)
        val scale = sqrt(NFFT.toDouble()) / NFFT // irfft (1/n) × sqrt(n_fft)
        for (t in 0 until frames) {
            for (f in 0 until BINS) {
                re[f] = spec[reOff + f * frames + t].toDouble()
                im[f] = spec[imOff + f * frames + t].toDouble()
            }
            re[BINS] = 0.0; im[BINS] = 0.0 // Nyquist
            im[0] = 0.0 // irfft ignora a parte imaginária do DC
            for (f in 1 until BINS) { // simetria hermitiana
                re[NFFT - f] = re[f]
                im[NFFT - f] = -im[f]
            }
            fft.transform(re, im, inverse = true)
            val p = (t + 2) * HOP
            for (i in 0 until NFFT) olaBuf[p + i] += re[i] * scale * win[i]
        }
        for (i in 0 until segment) out[i] += olaBuf[istftStart + i] * invEnv[i]
    }

    /** Modelo: (mag, mix) → (spec_out, time_out). */
    fun interface Predictor {
        fun predict(mag: FloatArray, mix: FloatArray, specOut: FloatArray, timeOut: FloatArray)
    }

    /** Lê [count] quadros estéreo a partir de [start] em left/right (já como float). */
    fun interface Reader {
        fun read(start: Long, count: Int, left: FloatArray, right: FloatArray)
    }

    /** Recebe o trecho pronto de cada fonte: data[s][c] com [count] amostras, a partir de dataOff. */
    fun interface Writer {
        fun write(data: Array<Array<FloatArray>>, count: Int)
    }

    /**
     * Separa a música inteira ([n] quadros). Normalização global (média/desvio do mono, como
     * demucs/separate.py) calculada por [meanStd]. Memória constante: acumulador rolante.
     */
    fun separate(
        n: Long,
        mean: Double,
        std: Double,
        reader: Reader,
        predictor: Predictor,
        writer: Writer,
        progress: (Double) -> Unit = {},
        cancelled: () -> Boolean = { false },
    ) {
        val L = segment
        val stride = ((1 - OVERLAP) * L).toInt()
        val w = DoubleArray(L) { i -> (if (i < L / 2) i + 1 else L - i).toDouble() / max(L / 2, L - L / 2) }
        val acc = Array(sources) { Array(2) { DoubleArray(L) } }
        val wacc = DoubleArray(L)
        val est = Array(sources) { Array(2) { DoubleArray(L) } }
        val chunk = FloatArray(2 * L)
        val left = FloatArray(L)
        val right = FloatArray(L)
        val mag = FloatArray(magSize)
        val specOut = FloatArray(specOutSize)
        val timeOut = FloatArray(timeOutSize)
        val outBuf = Array(sources) { Array(2) { FloatArray(stride.coerceAtLeast(L)) } }
        val sd = if (std < 1e-8) 1.0 else std
        var written = 0L
        var offset = 0L
        while (offset < n) {
            if (cancelled()) throw InterruptedException("cancelado")
            val chunkLen = min(L.toLong(), n - offset).toInt()
            val delta = L - chunkLen
            val start = offset - delta / 2
            java.util.Arrays.fill(chunk, 0f)
            val a = max(0L, start)
            val b = min(n, start + L)
            val cnt = (b - a).toInt()
            reader.read(a, cnt, left, right)
            val dst = (a - start).toInt()
            for (i in 0 until cnt) {
                chunk[dst + i] = ((left[i] - mean) / sd).toFloat()
                chunk[L + dst + i] = ((right[i] - mean) / sd).toFloat()
            }
            stft(chunk, mag)
            predictor.predict(mag, chunk, specOut, timeOut)
            for (s in 0 until sources) for (c in 0 until 2) {
                val e = est[s][c]
                val tBase = (s * 2 + c) * L
                for (i in 0 until L) e[i] = timeOut[tBase + i].toDouble()
                val sBase = s * magSize
                istftAdd(specOut, sBase + (2 * c) * BINS * frames, sBase + (2 * c + 1) * BINS * frames, e)
            }
            val lo = delta / 2
            for (s in 0 until sources) for (c in 0 until 2) {
                val ac = acc[s][c]; val e = est[s][c]
                for (i in 0 until chunkLen) ac[i] += w[i] * e[lo + i]
            }
            for (i in 0 until chunkLen) wacc[i] += w[i]
            val last = offset + stride >= n
            val final = if (last) chunkLen else stride
            for (s in 0 until sources) for (c in 0 until 2) {
                val ac = acc[s][c]; val o = outBuf[s][c]
                for (i in 0 until final) o[i] = (ac[i] / wacc[i] * sd + mean).toFloat()
            }
            writer.write(outBuf, final)
            written += final
            for (s in 0 until sources) for (c in 0 until 2) {
                val ac = acc[s][c]
                System.arraycopy(ac, stride, ac, 0, L - stride)
                java.util.Arrays.fill(ac, L - stride, L, 0.0)
            }
            System.arraycopy(wacc, stride, wacc, 0, L - stride)
            java.util.Arrays.fill(wacc, L - stride, L, 0.0)
            offset += stride
            progress(min(1.0, offset.toDouble() / n))
        }
        check(written == n) { "escrito $written de $n" }
    }
}
