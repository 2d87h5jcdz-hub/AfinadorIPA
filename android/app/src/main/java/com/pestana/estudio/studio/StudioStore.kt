package com.pestana.estudio.studio

import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.abs

/** Projetos em files/studio/<id>/project.json + um .pcm por gravação/importação. */
class StudioStore(filesDir: File) {
    val root = File(filesDir, "studio")
    val ampsDir = File(filesDir, "amps")

    fun folder(projectId: String) = File(root, projectId)
    fun file(projectId: String, fileName: String) = File(folder(projectId), fileName)

    fun loadAll(): List<StudioProject> =
        (root.listFiles() ?: emptyArray()).mapNotNull { dir ->
            try {
                StudioProject.fromJson(JSONObject(File(dir, "project.json").readText()))
            } catch (_: Exception) {
                null
            }
        }.sortedByDescending { it.updatedAt }

    fun save(p: StudioProject) {
        val dir = folder(p.id).also { it.mkdirs() }
        val tmp = File(dir, "project.json.tmp")
        tmp.writeText(p.toJson().toString(2))
        tmp.renameTo(File(dir, "project.json"))
    }

    fun delete(id: String) = folder(id).deleteRecursively()

    /** Apaga arquivos que nenhum clip usa mais. */
    fun deleteUnreferenced(candidates: Set<String>, p: StudioProject) {
        val used = StudioTimeline.referencedFiles(p)
        for (name in candidates) if (name.isNotEmpty() && name !in used) {
            file(p.id, name).delete()
            Waveforms.forget(file(p.id, name))
        }
    }
}

/** Picos da forma de onda (1 valor a cada [FRAMES] quadros), calculados uma vez por arquivo. */
object Waveforms {
    const val FRAMES = 480 // 10 ms a 48 kHz
    private val cache = ConcurrentHashMap<String, FloatArray>()

    fun get(file: File): FloatArray? = cache[file.path]

    fun compute(file: File): FloatArray {
        cache[file.path]?.let { return it }
        val peaks = RandomAccessFile(file, "r").use { raf ->
            val len = raf.length()
            if (len < 4) return FloatArray(0)
            val sb = raf.channel.map(FileChannel.MapMode.READ_ONLY, 0, len).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
            val frames = (len / 4).toInt()
            val n = (frames + FRAMES - 1) / FRAMES
            FloatArray(n) { k ->
                var m = 0
                val a = k * FRAMES
                val b = minOf(frames, a + FRAMES)
                var i = a
                while (i < b) {
                    val v = maxOf(abs(sb.get(2 * i).toInt()), abs(sb.get(2 * i + 1).toInt()))
                    if (v > m) m = v
                    i += 2 // metade das amostras basta para o desenho
                }
                m / 32768f
            }
        }
        cache[file.path] = peaks
        return peaks
    }

    fun forget(file: File) {
        cache.remove(file.path)
    }
}
