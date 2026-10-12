package com.pestana.estudio.studio

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

// Mesmo contrato do iOS (StudioModels.swift): nomes de campos iguais no project.json.
// Áudio no Android: PCM 16 bits estéreo intercalado a 48 kHz (.pcm) — tempos em segundos.

const val STUDIO_RATE = 48_000

data class StudioClip(
    val id: String = UUID.randomUUID().toString(),
    val fileName: String,
    /** Onde o clip começa na linha do tempo (s); já inclui a compensação de latência. */
    val offset: Double,
    /** Início dentro do arquivo (s). */
    val fileStart: Double = 0.0,
    /** Duração tocada (s). */
    val duration: Double,
) {
    val end get() = offset + duration

    fun toJson() = JSONObject().put("id", id).put("fileName", fileName).put("offset", offset)
        .put("fileStart", fileStart).put("duration", duration)

    companion object {
        fun fromJson(o: JSONObject) = StudioClip(
            o.optString("id", UUID.randomUUID().toString()), o.getString("fileName"),
            o.optDouble("offset", 0.0), o.optDouble("fileStart", 0.0), o.optDouble("duration", 0.0),
        )
    }
}

enum class EffectPreset(val key: String, val title: String) {
    NONE("none", "Sem efeito"),
    STEEL("steelGuitar", "Violão aço"),
    NYLON("nylonGuitar", "Violão nylon"),
    VOCAL("vocal", "Voz"),
    ELECTRIC_CLEAN("electricClean", "Guitarra limpa"),
    ELECTRIC_DRIVE("electricDrive", "Guitarra drive"),
    CRUNCH("crunch", "Crunch"),
    HIGH_GAIN("highGain", "Distorção pesada"),
    FUZZ("fuzz", "Fuzz"),
    SOLO("solo", "Solo"),
    CLEAN_CHORUS("cleanChorus", "Limpa com chorus"),
    FLANGER80("flanger80", "Flanger anos 80"),
    PHASER("phaser", "Phaser"),
    TREMOLO("tremolo", "Tremolo"),
    CUSTOM("custom", "Personalizado");

    companion object {
        fun byKey(k: String?) = entries.firstOrNull { it.key == k } ?: CUSTOM
    }
}

val DRIVE_STYLES = listOf("Distorção", "Crunch", "Funk", "Fuzz / lo-fi")
val MOD_TYPES = listOf("Nenhuma", "Chorus", "Flanger", "Phaser", "Tremolo")

/** Cadeia de efeitos (gate → EQ → compressor → drive → guitarra → delay → reverb). */
data class EffectSettings(
    val preset: EffectPreset = EffectPreset.NONE,
    val gateEnabled: Boolean = false,
    val gateThresholdDB: Float = -50f,
    val eqLowDB: Float = 0f,
    val eqMidDB: Float = 0f,
    val eqHighDB: Float = 0f,
    val compressorEnabled: Boolean = false,
    val compressorAmount: Float = 0.5f,
    val driveAmount: Float = 0f,
    val delayMix: Float = 0f,
    val delayTime: Float = 0.35f,
    val delayFeedback: Float = 0.3f,
    val reverbMix: Float = 0f,
    val driveStyle: Int = 0,
    /** Nome do arquivo .nam (na pasta de amps do app), ou null. */
    val ampModel: String? = null,
    val ampInputDB: Float = 0f,
    val ampOutputDB: Float = 0f,
    val modType: Int = 0,
    val modRate: Float = 0.6f,
    val modDepth: Float = 0.5f,
    val modMix: Float = 0.5f,
) {
    val isNeutral get() = copy(preset = EffectPreset.NONE) == EffectSettings()

    fun toJson(ampPath: String? = null): JSONObject = JSONObject().apply {
        put("preset", preset.key); put("gateEnabled", gateEnabled); put("gateThresholdDB", gateThresholdDB.toDouble())
        put("eqLowDB", eqLowDB.toDouble()); put("eqMidDB", eqMidDB.toDouble()); put("eqHighDB", eqHighDB.toDouble())
        put("compressorEnabled", compressorEnabled); put("compressorAmount", compressorAmount.toDouble())
        put("driveAmount", driveAmount.toDouble()); put("delayMix", delayMix.toDouble())
        put("delayTime", delayTime.toDouble()); put("delayFeedback", delayFeedback.toDouble())
        put("reverbMix", reverbMix.toDouble()); put("driveStyle", driveStyle)
        ampModel?.let { put("ampModel", it) }
        ampPath?.let { put("ampPath", it) }
        put("ampInputDB", ampInputDB.toDouble()); put("ampOutputDB", ampOutputDB.toDouble())
        put("modType", modType); put("modRate", modRate.toDouble()); put("modDepth", modDepth.toDouble())
        put("modMix", modMix.toDouble())
    }

    companion object {
        fun fromJson(o: JSONObject?): EffectSettings {
            if (o == null) return EffectSettings()
            fun f(k: String, d: Float) = o.optDouble(k, d.toDouble()).toFloat()
            val d = EffectSettings()
            return EffectSettings(
                preset = EffectPreset.byKey(o.optString("preset", "custom")),
                gateEnabled = o.optBoolean("gateEnabled", false), gateThresholdDB = f("gateThresholdDB", d.gateThresholdDB),
                eqLowDB = f("eqLowDB", 0f), eqMidDB = f("eqMidDB", 0f), eqHighDB = f("eqHighDB", 0f),
                compressorEnabled = o.optBoolean("compressorEnabled", false), compressorAmount = f("compressorAmount", d.compressorAmount),
                driveAmount = f("driveAmount", 0f), delayMix = f("delayMix", 0f), delayTime = f("delayTime", d.delayTime),
                delayFeedback = f("delayFeedback", d.delayFeedback), reverbMix = f("reverbMix", 0f),
                driveStyle = o.optInt("driveStyle", 0), ampModel = o.optString("ampModel", "").ifEmpty { null },
                ampInputDB = f("ampInputDB", 0f), ampOutputDB = f("ampOutputDB", 0f), modType = o.optInt("modType", 0),
                modRate = f("modRate", d.modRate), modDepth = f("modDepth", d.modDepth), modMix = f("modMix", d.modMix),
            )
        }

        fun preset(p: EffectPreset): EffectSettings {
            val s = EffectSettings(preset = p)
            return when (p) {
                EffectPreset.NONE, EffectPreset.CUSTOM -> s
                EffectPreset.STEEL -> s.copy(gateEnabled = true, gateThresholdDB = -55f, eqLowDB = -2f, eqMidDB = 1f, eqHighDB = 3f,
                    compressorEnabled = true, compressorAmount = 0.4f, reverbMix = 0.22f)
                EffectPreset.NYLON -> s.copy(gateEnabled = true, gateThresholdDB = -58f, eqLowDB = 1f, eqHighDB = 1.5f,
                    compressorEnabled = true, compressorAmount = 0.3f, reverbMix = 0.25f)
                EffectPreset.VOCAL -> s.copy(gateEnabled = true, gateThresholdDB = -45f, eqLowDB = -4f, eqMidDB = 1.5f, eqHighDB = 2.5f,
                    compressorEnabled = true, compressorAmount = 0.6f, delayMix = 0.08f, delayTime = 0.28f, delayFeedback = 0.2f, reverbMix = 0.18f)
                EffectPreset.ELECTRIC_CLEAN -> s.copy(eqMidDB = 2f, eqHighDB = 2f, compressorEnabled = true, compressorAmount = 0.5f,
                    delayMix = 0.15f, reverbMix = 0.2f)
                EffectPreset.ELECTRIC_DRIVE -> s.copy(gateEnabled = true, gateThresholdDB = -48f, eqLowDB = 2f, eqMidDB = 3f, eqHighDB = 1f,
                    driveAmount = 0.6f, reverbMix = 0.15f)
                EffectPreset.CRUNCH -> s.copy(gateEnabled = true, gateThresholdDB = -52f, eqLowDB = 1f, eqMidDB = 2f, eqHighDB = 1.5f,
                    driveStyle = 1, driveAmount = 0.45f, reverbMix = 0.15f)
                EffectPreset.HIGH_GAIN -> s.copy(gateEnabled = true, gateThresholdDB = -45f, eqLowDB = 3f, eqMidDB = -2f, eqHighDB = 2f,
                    driveStyle = 0, driveAmount = 0.85f, compressorEnabled = true, compressorAmount = 0.3f, reverbMix = 0.12f)
                EffectPreset.FUZZ -> s.copy(gateEnabled = true, gateThresholdDB = -48f, eqLowDB = 2f, eqMidDB = 1f, eqHighDB = -1f,
                    driveStyle = 3, driveAmount = 0.7f, reverbMix = 0.1f)
                EffectPreset.SOLO -> s.copy(gateEnabled = true, gateThresholdDB = -48f, eqMidDB = 3f, eqHighDB = 1.5f,
                    compressorEnabled = true, compressorAmount = 0.5f, driveStyle = 0, driveAmount = 0.7f,
                    delayMix = 0.25f, delayTime = 0.38f, delayFeedback = 0.35f, reverbMix = 0.25f)
                EffectPreset.CLEAN_CHORUS -> s.copy(eqLowDB = -1f, eqHighDB = 2f, compressorEnabled = true, compressorAmount = 0.4f,
                    modType = 1, modRate = 0.8f, modDepth = 0.55f, modMix = 0.5f, reverbMix = 0.2f)
                EffectPreset.FLANGER80 -> s.copy(eqMidDB = 1f, eqHighDB = 2f, driveStyle = 1, driveAmount = 0.3f,
                    modType = 2, modRate = 0.25f, modDepth = 0.8f, modMix = 0.6f, reverbMix = 0.15f)
                EffectPreset.PHASER -> s.copy(eqMidDB = 1f, eqHighDB = 1f, driveStyle = 1, driveAmount = 0.25f,
                    modType = 3, modRate = 0.5f, modDepth = 0.7f, modMix = 0.6f, reverbMix = 0.15f)
                EffectPreset.TREMOLO -> s.copy(eqHighDB = 1.5f, modType = 4, modRate = 5f, modDepth = 0.7f, modMix = 1f, reverbMix = 0.25f)
            }
        }
    }
}

data class StudioTrack(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val volume: Float = 1f,
    val pan: Float = 0f,
    val isMuted: Boolean = false,
    val isSolo: Boolean = false,
    val effects: EffectSettings = EffectSettings(),
    val isImported: Boolean = false,
    val clips: List<StudioClip> = emptyList(),
    val effectsOn: Boolean = true,
) {
    val end get() = clips.maxOfOrNull { it.end } ?: 0.0
    val hasEffects get() = !effects.isNeutral

    /** Id numérico para o motor nativo (estável enquanto o UUID não muda). */
    val nativeId: Long get() = UUID.fromString(id).mostSignificantBits

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id); put("name", name); put("volume", volume.toDouble()); put("pan", pan.toDouble())
        put("isMuted", isMuted); put("isSolo", isSolo); put("effects", effects.toJson())
        put("isImported", isImported); put("effectsOn", effectsOn)
        put("clips", JSONArray().apply { clips.forEach { put(it.toJson()) } })
    }

    companion object {
        fun fromJson(o: JSONObject): StudioTrack {
            val clips = o.optJSONArray("clips")?.let { a -> (0 until a.length()).map { StudioClip.fromJson(a.getJSONObject(it)) } }
                ?: emptyList()
            val id = o.optString("id").let { if (runCatching { UUID.fromString(it) }.isSuccess) it else UUID.randomUUID().toString() }
            return StudioTrack(
                id = id, name = o.optString("name", "Faixa"), volume = o.optDouble("volume", 1.0).toFloat(),
                pan = o.optDouble("pan", 0.0).toFloat(), isMuted = o.optBoolean("isMuted"), isSolo = o.optBoolean("isSolo"),
                effects = EffectSettings.fromJson(o.optJSONObject("effects")), isImported = o.optBoolean("isImported"),
                clips = clips.sortedBy { it.offset }, effectsOn = o.optBoolean("effectsOn", true),
            )
        }
    }
}

data class StudioProject(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val bpm: Double = 90.0,
    val beatsPerBar: Int = 4,
    val tracks: List<StudioTrack> = emptyList(),
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
) {
    val duration get() = tracks.maxOfOrNull { it.end } ?: 0.0

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id); put("name", name); put("bpm", bpm); put("beatsPerBar", beatsPerBar)
        put("createdAt", createdAt); put("updatedAt", updatedAt)
        put("tracks", JSONArray().apply { tracks.forEach { put(it.toJson()) } })
    }

    companion object {
        fun fromJson(o: JSONObject) = StudioProject(
            id = o.getString("id"), name = o.optString("name", "Música"), bpm = o.optDouble("bpm", 90.0),
            beatsPerBar = o.optInt("beatsPerBar", 4),
            tracks = o.optJSONArray("tracks")?.let { a -> (0 until a.length()).map { StudioTrack.fromJson(a.getJSONObject(it)) } } ?: emptyList(),
            createdAt = o.optLong("createdAt", System.currentTimeMillis()), updatedAt = o.optLong("updatedAt", System.currentTimeMillis()),
        )
    }
}

enum class Transport { STOPPED, PLAYING, COUNT_IN, RECORDING }

object StudioTimeline {
    private const val MIN_CLIP = 0.005

    /** Punch-in: o trecho do clip novo substitui o que houver por baixo (apara/divide; nunca mexe nos arquivos). */
    fun punchIn(newClip: StudioClip, clips: List<StudioClip>): List<StudioClip> {
        val a = newClip.offset
        val b = newClip.end
        val out = mutableListOf<StudioClip>()
        for (c in clips) {
            if (c.end <= a || c.offset >= b) { out += c; continue }
            if (c.offset < a) {
                val left = c.copy(duration = a - c.offset)
                if (left.duration >= MIN_CLIP) out += left
            }
            if (c.end > b) {
                val cut = b - c.offset
                val right = c.copy(
                    id = if (c.offset < a) UUID.randomUUID().toString() else c.id,
                    offset = b, fileStart = c.fileStart + cut, duration = c.end - b,
                )
                if (right.duration >= MIN_CLIP) out += right
            }
        }
        out += newClip
        return out.sortedBy { it.offset }
    }

    fun referencedFiles(p: StudioProject): Set<String> = p.tracks.flatMap { t -> t.clips.map { it.fileName } }.toSet()
}
