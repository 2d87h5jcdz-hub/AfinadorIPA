package com.pestana.estudio.practice

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import com.pestana.estudio.audio.AacEncoder
import com.pestana.estudio.audio.PcmFile
import com.pestana.estudio.audio.PcmWriter
import com.pestana.estudio.core.DemucsDsp
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.FloatBuffer
import kotlin.math.sqrt

/**
 * Modelo de IA (HTDemucs 6 fontes, Meta, licença MIT) em ONNX. Não vai dentro do APK
 * (115 MB): é baixado da release "demucs-model" do GitHub na primeira separação.
 */
class ModelStore(filesDir: File) {
    companion object {
        const val URL_MODEL = "https://github.com/2d87h5jcdz-hub/PestanaEstudio/releases/download/demucs-model/HTDemucs.onnx"
        const val APPROX_MB = 115
    }

    private val dir = File(filesDir, "models")
    val file = File(dir, "HTDemucs.onnx")
    val isReady: Boolean get() = file.exists() && file.length() > 10_000_000

    /** Baixa o modelo (com retomada se cair no meio). */
    fun download(progress: (Double) -> Unit, cancelled: () -> Boolean) {
        dir.mkdirs()
        val part = File(dir, "HTDemucs.onnx.part")
        var url = URL(URL_MODEL)
        var conn: HttpURLConnection
        var redirects = 0
        while (true) {
            conn = url.openConnection() as HttpURLConnection
            conn.connectTimeout = 20_000
            conn.readTimeout = 30_000
            conn.instanceFollowRedirects = false
            if (part.exists() && part.length() > 0) conn.setRequestProperty("Range", "bytes=${part.length()}-")
            val code = conn.responseCode
            if (code in 300..399 && redirects++ < 5) {
                url = URL(url, conn.getHeaderField("Location"))
                conn.disconnect()
                continue
            }
            break
        }
        val code = conn.responseCode
        val resume = code == 206
        if (code != 200 && !resume) throw IOException("download do modelo falhou (HTTP $code)")
        val already = if (resume) part.length() else 0L
        val total = already + conn.contentLengthLong.coerceAtLeast(0)
        conn.inputStream.use { input ->
            java.io.FileOutputStream(part, resume).use { out ->
                val buf = ByteArray(1 shl 16)
                var got = already
                var last = 0L
                while (true) {
                    if (cancelled()) throw InterruptedException("cancelado")
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    got += n
                    if (total > 0 && got - last > 512 * 1024) { progress(got.toDouble() / total); last = got }
                }
            }
        }
        conn.disconnect()
        if (part.length() < 10_000_000) throw IOException("download incompleto")
        if (!part.renameTo(file)) throw IOException("não consegui salvar o modelo")
        progress(1.0)
    }

    fun delete() {
        file.delete()
        File(dir, "HTDemucs.onnx.part").delete()
    }
}

private fun procMb(key: String): Long = try {
    java.io.File("/proc/self/status").readLines().first { it.startsWith(key) }
        .filter { it.isDigit() }.toLong() / 1024
} catch (_: Exception) {
    -1
}

private fun rssMb(): String = "${procMb("VmRSS:")} MB (pico ${procMb("VmHWM:")} MB)"

/** Roda o HTDemucs (ONNX Runtime, CPU) sobre a música inteira e grava um arquivo por stem. */
class DemucsOnnxSeparator(private val model: File) {

    class Result(val stems: Map<StemKind, File>)

    /**
     * @param pcmCacheFor onde gravar o PCM de cada stem (fica pronto para tocar na hora)
     * @param m4aFor onde gravar a cópia compactada (a que fica guardada)
     */
    fun separate(
        song: PcmFile,
        pcmCacheFor: (StemKind) -> File,
        m4aFor: (StemKind) -> File,
        progress: (Double) -> Unit,
        cancelled: () -> Boolean,
    ): Result {
        val env = OrtEnvironment.getEnvironment()
        val opts = OrtSession.SessionOptions().apply {
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            setIntraOpNumThreads(Runtime.getRuntime().availableProcessors().coerceIn(2, 6))
            // Sem arena nem padrão de memória: a memória da inferência volta ao sistema entre
            // segmentos (com a arena o pico chegava a ~3 GB e o Android matava o app).
            setCPUArenaAllocator(false)
            setMemoryPatternOptimization(false)
        }
        val session = env.createSession(model.path, opts)
        try {
            val sourcesMeta = session.metadata.customMetadata["sources"]
                ?: "drums,bass,other,vocals,guitar,piano"
            val names = sourcesMeta.split(",").map { it.trim() }
            val kinds = names.map { StemKind.byKey(it) ?: throw IOException("fonte desconhecida no modelo: $it") }
            val mixShape = (session.inputInfo["mix"]?.info as? ai.onnxruntime.TensorInfo)?.shape
                ?: throw IOException("modelo sem a entrada 'mix'")
            val segment = mixShape[2].toInt()
            val dsp = DemucsDsp(segment, kinds.size)
            val T = dsp.frames.toLong()

            // Normalização global: média e desvio do mono da música inteira.
            val n = song.frames
            val l = FloatArray(65536)
            val r = FloatArray(65536)
            var sum = 0.0
            var sq = 0.0
            var p = 0L
            while (p < n) {
                if (cancelled()) throw InterruptedException("cancelado")
                val c = minOf(65536L, n - p).toInt()
                song.read(p, c, l, r)
                for (i in 0 until c) {
                    val m = (l[i] + r[i]) * 0.5
                    sum += m; sq += m * m
                }
                p += c
            }
            val mean = sum / n
            val std = if (n > 1) sqrt(((sq - n * mean * mean) / (n - 1)).coerceAtLeast(0.0)) else 1.0

            var tensors: List<OnnxTensor>? = null
            val writers = kinds.map { PcmWriter(pcmCacheFor(it).also { f -> f.parentFile?.mkdirs() }) }
            try {
                dsp.separate(
                    n, mean, std,
                    reader = { start, count, left, right -> song.read(start, count, left, right) },
                    predictor = { mag, mix, specOut, timeOut ->
                        val t0 = System.nanoTime()
                        if (tensors == null) {
                            // Entradas e saídas apontam para os mesmos buffers diretos em todo segmento.
                            tensors = listOf(
                                OnnxTensor.createTensor(env, mag, longArrayOf(1, 4, DemucsDsp.BINS.toLong(), T)),
                                OnnxTensor.createTensor(env, mix, longArrayOf(1, 2, segment.toLong())),
                                OnnxTensor.createTensor(env, specOut, longArrayOf(1, kinds.size.toLong(), 4, DemucsDsp.BINS.toLong(), T)),
                                OnnxTensor.createTensor(env, timeOut, longArrayOf(1, kinds.size.toLong(), 2, segment.toLong())),
                            )
                        }
                        val t = tensors!!
                        session.run(
                            mapOf("mag" to t[0], "mix" to t[1]),
                            mapOf("spec_out" to t[2], "time_out" to t[3]),
                        ).close()
                        android.util.Log.i(
                            "Pestana",
                            "Demucs: segmento em %.1f s, memória %s".format((System.nanoTime() - t0) / 1e9, rssMb()),
                        )
                    },
                    writer = { data, count ->
                        for (s in kinds.indices) writers[s].write(data[s][0], data[s][1], count)
                    },
                    progress = { progress(0.9 * it) },
                    cancelled = cancelled,
                    directBuffers = true,
                )
            } finally {
                writers.forEach { it.close() }
                tensors?.forEach { it.close() }
            }

            // Cópia compactada (AAC) para guardar; o PCM fica no cache para tocar.
            val out = mutableMapOf<StemKind, File>()
            kinds.forEachIndexed { i, kind ->
                val dest = m4aFor(kind).also { it.parentFile?.mkdirs() }
                PcmFile(pcmCacheFor(kind)).use { pcm -> AacEncoder.encode(pcm, dest, cancelled = cancelled) }
                out[kind] = dest
                progress(0.9 + 0.1 * (i + 1) / kinds.size)
            }
            return Result(out)
        } finally {
            session.close()
            opts.close()
        }
    }
}
