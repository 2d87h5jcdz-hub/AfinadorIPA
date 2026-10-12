package com.pestana.estudio.practice

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Instrumentos que o separador pode devolver (mesma ordem/nomes do iOS). */
enum class StemKind(val key: String, val title: String) {
    VOCALS("vocals", "Voz"),
    DRUMS("drums", "Bateria"),
    BASS("bass", "Baixo"),
    GUITAR("guitar", "Violão/Guitarra"),
    PIANO("piano", "Piano"),
    OTHER("other", "Outros");

    companion object {
        fun byKey(k: String): StemKind? = entries.firstOrNull { it.key == k.lowercase() }
    }
}

/**
 * Uma música importada. Arquivos em files/practice/<id>/ (song.<ext> e stems/<stem>.m4a);
 * o áudio decodificado (PCM) fica em cache/practice/<id>/ e é refeito se o Android limpar.
 */
data class PracticeSong(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val fileName: String,
    val duration: Double,
    val addedAt: Long = System.currentTimeMillis(),
    /** StemKind.key → nome do arquivo em stems/. */
    val stemFiles: Map<String, String> = emptyMap(),
    val semitones: Int = 0,
    val speed: Double = 1.0,
    /** Tom original informado pelo usuário (0 = C … 11 = B). */
    val originalKey: Int? = null,
) {
    val hasStems: Boolean get() = stemFiles.isNotEmpty()

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id); put("title", title); put("fileName", fileName); put("duration", duration)
        put("addedAt", addedAt); put("semitones", semitones); put("speed", speed)
        originalKey?.let { put("originalKey", it) }
        put("stemFiles", JSONObject(stemFiles))
    }

    companion object {
        fun fromJson(o: JSONObject): PracticeSong {
            val stems = mutableMapOf<String, String>()
            o.optJSONObject("stemFiles")?.let { s -> s.keys().forEach { k -> stems[k] = s.getString(k) } }
            return PracticeSong(
                id = o.getString("id"),
                title = o.getString("title"),
                fileName = o.getString("fileName"),
                duration = o.optDouble("duration", 0.0),
                addedAt = o.optLong("addedAt", 0L),
                stemFiles = stems,
                semitones = o.optInt("semitones", 0),
                speed = o.optDouble("speed", 1.0),
                originalKey = if (o.has("originalKey")) o.getInt("originalKey") else null,
            )
        }
    }
}

/** Biblioteca persistida em files/practice/library.json. */
class PracticeLibrary(private val filesDir: File, private val cacheDir: File) {
    val root = File(filesDir, "practice")
    private val json = File(root, "library.json")

    fun folder(song: PracticeSong) = File(root, song.id)
    fun songFile(song: PracticeSong) = File(folder(song), song.fileName)
    fun stemsFolder(song: PracticeSong) = File(folder(song), "stems")
    fun cacheFolder(song: PracticeSong) = File(File(cacheDir, "practice"), song.id)
    fun songPcm(song: PracticeSong) = File(cacheFolder(song), "song.pcm")
    fun stemPcm(song: PracticeSong, kind: StemKind) = File(cacheFolder(song), "${kind.key}.pcm")

    fun load(): List<PracticeSong> = try {
        val arr = JSONArray(json.readText())
        (0 until arr.length()).map { PracticeSong.fromJson(arr.getJSONObject(it)) }.filter { songFile(it).exists() }
    } catch (_: Exception) {
        emptyList()
    }

    fun save(list: List<PracticeSong>) {
        root.mkdirs()
        val arr = JSONArray()
        list.forEach { arr.put(it.toJson()) }
        val tmp = File(root, "library.json.tmp")
        tmp.writeText(arr.toString(2))
        tmp.renameTo(json)
    }
}

object PracticeNotes {
    private val names = listOf("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")
    fun name(pc: Int) = names[((pc % 12) + 12) % 12]
    fun transposed(key: Int, by: Int) = name(key + by)
    fun intervalText(st: Int) = when (st) {
        0 -> "Tom original"
        1 -> "+1 semitom"
        -1 -> "−1 semitom"
        else -> if (st > 0) "+$st semitons" else "−${-st} semitons"
    }

    fun time(t: Double): String {
        if (!t.isFinite() || t < 0) return "0:00"
        val s = t.toInt()
        return "%d:%02d".format(s / 60, s % 60)
    }
}
