package com.pestana.estudio.studio

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.provider.OpenableColumns
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import com.pestana.estudio.audio.AacEncoder
import com.pestana.estudio.audio.AudioDecoder
import com.pestana.estudio.audio.PcmFile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID
import kotlin.math.max
import kotlin.math.roundToLong

/**
 * Estúdio: projetos, gravação em camadas (clips na linha do tempo, punch-in), efeitos,
 * retorno ao vivo e exportação. O áudio em tempo real é o motor C++/Oboe ([NativeStudio]).
 */
class StudioEngine(context: Context) {
    private val app = context.applicationContext
    val store = StudioStore(app.filesDir)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val prefs = app.getSharedPreferences("pestana", Context.MODE_PRIVATE)
    private val native: NativeStudio? = try {
        NativeStudio()
    } catch (e: Throwable) {
        null
    }

    // Estado publicado
    var projects by mutableStateOf(store.loadAll())
        private set
    var project by mutableStateOf<StudioProject?>(null)
        private set
    var transport by mutableStateOf(Transport.STOPPED)
        private set
    var countInBeat by mutableIntStateOf(0)
        private set
    var position by mutableDoubleStateOf(0.0)
        private set
    var inputLevel by mutableFloatStateOf(0f)
        private set
    val trackLevels = mutableStateMapOf<String, Float>()
    var armedTrackId by mutableStateOf<String?>(null)
        private set
    var recordingStart by mutableStateOf<Double?>(null)
        private set
    var lastError by mutableStateOf<String?>(null)
    var busy by mutableStateOf<String?>(null)
        private set

    var clickEnabled by mutableStateOf(prefs.getBoolean("studioClick", true))
        private set
    var countInBars by mutableIntStateOf(prefs.getInt("studioCountIn", 1))
        private set
    var monitorEnabled by mutableStateOf(false)
        private set
    var monitorEffects by mutableStateOf(EffectSettings())
        private set
    var inputGainDb by mutableFloatStateOf(prefs.getFloat("studioGain", 0f))
        private set
    var inputName by mutableStateOf("Microfone do celular")
        private set
    var headphones by mutableStateOf(false)
        private set
    /** Ajuste fino da compensação de latência (ms, somado ao valor medido). */
    var latencyAdjustMs by mutableFloatStateOf(prefs.getFloat("studioLatencyAdjust", 0f))
        private set

    val duration: Double get() = project?.duration ?: 0.0
    val available: Boolean get() = native != null

    private var active = false
    private var ticker: Job? = null
    private var take: PendingTake? = null
    private var playStartPosition = 0.0

    private class PendingTake(
        val file: File,
        val startPosition: Double,
        val latency: Double,
        val trackId: String,
        val createdTrack: Boolean,
    )

    // MARK: ciclo de vida

    fun hasMicPermission() =
        ContextCompat.checkSelfPermission(app, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    /** Ao entrar na aba: abre o áudio (com microfone, se liberado). */
    fun activate() {
        val n = native ?: run { lastError = "O motor de áudio do Estúdio não carregou neste aparelho."; return }
        active = true
        n.open(hasMicPermission())?.let { if (hasMicPermission()) lastError = "Áudio: $it" }
        n.setInputGain(inputGainDb)
        n.setMonitor(monitorEnabled, monitorEffects.toJson(ampPath(monitorEffects)).toString())
        project?.let { pushSong(it); n.setClick(it.bpm, it.beatsPerBar, clickEnabled) }
        updateRoute()
        startTicker()
    }

    /** Ao sair da aba (ou app em segundo plano): para tudo e libera o microfone. */
    fun deactivate() {
        if (transport != Transport.STOPPED) stop()
        active = false
        ticker?.cancel()
        ticker = null
        native?.close()
        inputLevel = 0f
    }

    /** Microfone acabou de ser liberado: reabre em duplex. */
    fun micGranted() {
        if (active) native?.open(true)
        updateRoute()
    }

    private fun updateRoute() {
        val am = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val inputs = am.getDevices(AudioManager.GET_DEVICES_INPUTS)
        val outputs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val ext = inputs.firstOrNull {
            it.type == AudioDeviceInfo.TYPE_USB_DEVICE || it.type == AudioDeviceInfo.TYPE_USB_HEADSET ||
                it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET
        }
        inputName = ext?.productName?.toString()?.takeIf { it.isNotBlank() }
            ?: if (ext != null) "Entrada externa" else "Microfone do celular"
        headphones = outputs.any {
            it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES || it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                it.type == AudioDeviceInfo.TYPE_USB_HEADSET || it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                it.type == AudioDeviceInfo.TYPE_USB_DEVICE
        }
    }

    // MARK: projetos

    fun newProject(name: String): StudioProject {
        stopForSwitch()
        val p = StudioProject(name = name.ifBlank { "Música ${projects.size + 1}" })
        store.save(p)
        projects = listOf(p) + projects
        openProject(p)
        return p
    }

    fun open(id: String) {
        projects.firstOrNull { it.id == id }?.let { openProject(it) }
    }

    private fun openProject(p: StudioProject) {
        stopForSwitch()
        project = p
        position = 0.0
        armedTrackId = null
        pushSong(p)
        native?.setClick(p.bpm, p.beatsPerBar, clickEnabled)
        scope.launch(Dispatchers.IO) { p.tracks.flatMap { it.clips }.forEach { Waveforms.compute(store.file(p.id, it.fileName)) } }
    }

    fun closeProject() {
        stopForSwitch()
        project = null
        native?.setSong("""{"tracks":[]}""")
    }

    fun rename(id: String, name: String) {
        val n = name.trim().ifEmpty { return }
        if (project?.id == id) update { it.copy(name = n) } else {
            projects.firstOrNull { it.id == id }?.let { val u = it.copy(name = n); store.save(u); projects = projects.map { p -> if (p.id == id) u else p } }
        }
    }

    fun deleteProject(id: String) {
        if (project?.id == id) closeProject()
        store.delete(id)
        projects = projects.filter { it.id != id }
    }

    private fun stopForSwitch() {
        if (transport != Transport.STOPPED) stop()
    }

    /** Altera o projeto aberto, salva e (se mudou a estrutura) atualiza o motor. */
    private fun update(structural: Boolean = false, f: (StudioProject) -> StudioProject) {
        val old = project ?: return
        val p = f(old).copy(updatedAt = System.currentTimeMillis())
        project = p
        projects = listOf(p) + projects.filter { it.id != p.id }
        scope.launch(Dispatchers.IO) { store.save(p) }
        if (structural) pushSong(p)
    }

    // MARK: motor (disposição)

    private fun ampPath(e: EffectSettings): String? = e.ampModel?.let { File(store.ampsDir, it).path }

    private fun songJson(p: StudioProject): String {
        val tracks = JSONArray()
        for (t in p.tracks) {
            val clips = JSONArray()
            for (c in t.clips) {
                clips.put(
                    JSONObject().put("path", store.file(p.id, c.fileName).path)
                        .put("offset", (c.offset * STUDIO_RATE).roundToLong())
                        .put("fileStart", (c.fileStart * STUDIO_RATE).roundToLong())
                        .put("duration", (c.duration * STUDIO_RATE).roundToLong()),
                )
            }
            tracks.put(
                JSONObject().put("id", t.nativeId).put("volume", t.volume.toDouble()).put("pan", t.pan.toDouble())
                    .put("mute", t.isMuted).put("solo", t.isSolo).put("fxOn", t.effectsOn)
                    .put("fx", t.effects.toJson(ampPath(t.effects))).put("clips", clips),
            )
        }
        return JSONObject().put("tracks", tracks).toString()
    }

    private fun pushSong(p: StudioProject) {
        native?.setSong(songJson(p))?.let { lastError = "Áudio: $it" }
    }

    // MARK: transporte

    fun play(from: Double? = null) {
        if (transport == Transport.COUNT_IN || transport == Transport.RECORDING) return
        val p = project ?: return
        val n = native ?: return
        if (!active) activate()
        var start = max(0.0, from ?: position)
        if (duration > 0 && start >= duration - 0.05) start = 0.0
        n.setClick(p.bpm, p.beatsPerBar, clickEnabled)
        n.start((start * STUDIO_RATE).roundToLong(), 0, null, -1)?.let { lastError = it; return }
        playStartPosition = start
        position = start
        transport = Transport.PLAYING
    }

    fun togglePlay() = if (transport == Transport.STOPPED) play() else stop()

    /** Para. Depois de gravar, a cabeça volta ao começo da tomada; parado, volta ao início. */
    fun stop() {
        val n = native ?: return
        when (transport) {
            Transport.STOPPED -> position = 0.0
            Transport.PLAYING -> {
                n.stop()
                transport = Transport.STOPPED
            }
            Transport.COUNT_IN, Transport.RECORDING -> {
                val reached = transport == Transport.RECORDING
                val frames = n.stop()
                transport = Transport.STOPPED
                position = take?.startPosition ?: playStartPosition
                recordingStart = null
                finishTake(frames, reached)
            }
        }
        trackLevels.clear()
    }

    fun seek(t: Double) {
        if (transport == Transport.COUNT_IN || transport == Transport.RECORDING) return
        val target = t.coerceIn(0.0, max(duration, position) + 600)
        if (transport == Transport.PLAYING) {
            if (duration > 0 && target >= duration - 0.05) {
                native?.stop(); transport = Transport.STOPPED; position = target; return
            }
            native?.start((target * STUDIO_RATE).roundToLong(), 0, null, -1)
            playStartPosition = target
        }
        position = target
    }

    fun seekToEnd(trackId: String) {
        project?.tracks?.firstOrNull { it.id == trackId }?.let { seek(it.end) }
    }

    fun record() {
        if (transport == Transport.COUNT_IN || transport == Transport.RECORDING) return
        val p = project ?: return
        val n = native ?: return
        if (!hasMicPermission()) { lastError = "Libere o microfone para gravar."; return }
        if (!active) activate()
        if (!n.hasInput()) {
            n.open(true)
            if (!n.hasInput()) { lastError = "Não consegui abrir o microfone."; return }
        }
        if (transport == Transport.PLAYING) { n.stop(); transport = Transport.STOPPED }
        val start = max(0.0, position)
        val folder = store.folder(p.id).also { it.mkdirs() }
        val file = File(folder, "take-${UUID.randomUUID()}.pcm")

        // Faixa de destino: a armada; sem nada armado, cria uma faixa nova e a arma.
        val armed = armedTrackId?.takeIf { id -> p.tracks.any { it.id == id } }
        val targetId: String
        val created: Boolean
        if (armed != null) {
            targetId = armed; created = false
        } else {
            val t = StudioTrack(name = nextTrackName(p), effects = monitorEffects)
            update { it.copy(tracks = it.tracks + t) }
            armedTrackId = t.id
            targetId = t.id; created = true
        }
        val target = project!!.tracks.first { it.id == targetId }
        val beat = 60.0 / max(20.0, p.bpm)
        val lead = countInBars * max(1, p.beatsPerBar) * beat
        val latency = (n.latencyMs() + latencyAdjustMs) / 1000.0
        take = PendingTake(file, start, latency, targetId, created)
        n.setClick(p.bpm, p.beatsPerBar, clickEnabled)
        n.start((start * STUDIO_RATE).roundToLong(), (lead * STUDIO_RATE).roundToLong(), file.path, target.nativeId)?.let {
            lastError = it
            take = null
            file.delete()
            if (created) removeTrackIfEmpty(targetId)
            return
        }
        playStartPosition = start
        position = start
        recordingStart = start
        transport = if (lead > 0) Transport.COUNT_IN else Transport.RECORDING
        countInBeat = 1
    }

    private fun nextTrackName(p: StudioProject): String {
        val names = p.tracks.map { it.name }.toSet()
        var k = p.tracks.size + 1
        while ("Faixa $k" in names) k++
        return "Faixa $k"
    }

    private fun finishTake(frames: Long, reportEmpty: Boolean) {
        val pending = take ?: return
        take = null
        recordingStart = null
        val seconds = frames.toDouble() / STUDIO_RATE
        fun discard() {
            pending.file.delete()
            if (pending.createdTrack) removeTrackIfEmpty(pending.trackId)
        }
        if (seconds < 0.2) {
            discard()
            if (reportEmpty) lastError = "A gravação ficou curta demais e não foi salva."
            return
        }
        // Compensação de latência: o clip começa "latency" antes (o começo antes de 0 é aparado).
        var clip = StudioClip(fileName = pending.file.name, offset = pending.startPosition - pending.latency, duration = seconds)
        if (clip.offset < 0) {
            val cut = -clip.offset
            clip = clip.copy(offset = 0.0, fileStart = cut, duration = seconds - cut)
        }
        if (clip.duration < 0.05) { discard(); return }
        val p = project ?: return
        val idx = p.tracks.indexOfFirst { it.id == pending.trackId }
        if (idx >= 0) {
            val track = p.tracks[idx]
            val previous = track.clips.map { it.fileName }.toSet()
            val fx = if (track.clips.isEmpty() && track.effects.isNeutral) monitorEffects else track.effects
            val updated = track.copy(clips = StudioTimeline.punchIn(clip, track.clips), effects = fx)
            update(structural = true) { it.copy(tracks = it.tracks.toMutableList().also { l -> l[idx] = updated }) }
            store.deleteUnreferenced(previous, project!!)
        } else {
            val t = StudioTrack(name = nextTrackName(p), effects = monitorEffects, clips = listOf(clip))
            update(structural = true) { it.copy(tracks = it.tracks + t) }
            armedTrackId = t.id
        }
        scope.launch(Dispatchers.IO) { Waveforms.compute(pending.file) }
    }

    private fun removeTrackIfEmpty(id: String) {
        val p = project ?: return
        if (p.tracks.firstOrNull { it.id == id }?.clips?.isEmpty() == true) {
            update { it.copy(tracks = it.tracks.filter { t -> t.id != id }) }
            if (armedTrackId == id) armedTrackId = null
        }
    }

    // MARK: ticker (~30 Hz): posição, contagem e medidores

    private fun startTicker() {
        ticker?.cancel()
        ticker = scope.launch {
            while (isActive) {
                tick()
                delay(33)
            }
        }
    }

    private fun tick() {
        val n = native ?: return
        val lv = n.levels()
        if (lv.isNotEmpty()) {
            val v = max(lv[0], inputLevel * 0.82f)
            inputLevel = if (v < 0.01f) 0f else v
        }
        if (transport == Transport.STOPPED) return
        val st = n.status()
        val songTime = st[1].toDouble() / STUDIO_RATE
        when (transport) {
            Transport.COUNT_IN -> {
                if (st[0] == 3L) transport = Transport.RECORDING
                else {
                    val p = project
                    if (p != null) {
                        val idx = Math.floor(songTime / (60.0 / max(20.0, p.bpm))).toLong()
                        val bpb = max(1, p.beatsPerBar)
                        countInBeat = (((idx % bpb) + bpb) % bpb).toInt() + 1
                    }
                }
                position = playStartPosition
            }
            Transport.RECORDING -> position = max(playStartPosition, songTime)
            Transport.PLAYING -> {
                position = max(0.0, songTime)
                if (duration > 0 && position >= duration + 0.1) {
                    stop()
                    position = 0.0
                    return
                }
            }
            Transport.STOPPED -> Unit
        }
        val p = project ?: return
        p.tracks.forEachIndexed { i, t ->
            val v = lv.getOrElse(i + 1) { 0f }
            val prev = trackLevels[t.id] ?: 0f
            val nv = max(v, prev * 0.82f)
            trackLevels[t.id] = if (nv < 0.01f) 0f else nv
        }
    }

    // MARK: faixas

    /** Nome, volume, pan, mudo, solo, efeitos, FX (os clips vêm do projeto atual, não do parâmetro). */
    fun updateTrack(t: StudioTrack) {
        val p = project ?: return
        val old = p.tracks.firstOrNull { it.id == t.id } ?: return
        val merged = t.copy(clips = old.clips)
        update { it.copy(tracks = it.tracks.map { x -> if (x.id == t.id) merged else x }) }
        native?.setTrackMix(merged.nativeId, merged.volume, merged.pan, merged.isMuted, merged.isSolo, merged.effectsOn)
        if (merged.effects != old.effects) native?.setTrackFx(merged.nativeId, merged.effects.toJson(ampPath(merged.effects)).toString())
    }

    fun deleteTrack(id: String) {
        if (transport != Transport.STOPPED) stop()
        val p = project ?: return
        val files = p.tracks.firstOrNull { it.id == id }?.clips?.map { it.fileName }?.toSet() ?: emptySet()
        update(structural = true) { it.copy(tracks = it.tracks.filter { t -> t.id != id }) }
        if (armedTrackId == id) armedTrackId = null
        store.deleteUnreferenced(files, project!!)
    }

    fun addEmptyTrack(): StudioTrack? {
        val p = project ?: return null
        val t = StudioTrack(name = nextTrackName(p), effects = monitorEffects)
        update(structural = true) { it.copy(tracks = it.tracks + t) }
        armedTrackId = t.id
        return t
    }

    fun arm(id: String?) {
        if (transport != Transport.STOPPED) return
        armedTrackId = if (armedTrackId == id) null else id
    }

    fun moveClip(clipId: String, trackId: String, offset: Double) {
        if (transport != Transport.STOPPED) return
        update(structural = true) { p ->
            p.copy(tracks = p.tracks.map { t ->
                if (t.id != trackId) t else t.copy(clips = t.clips.map { c -> if (c.id == clipId) c.copy(offset = max(0.0, offset)) else c }.sortedBy { it.offset })
            })
        }
    }

    fun deleteClip(clipId: String, trackId: String) {
        if (transport != Transport.STOPPED) return
        val p = project ?: return
        val file = p.tracks.firstOrNull { it.id == trackId }?.clips?.firstOrNull { it.id == clipId }?.fileName
        update(structural = true) { pr ->
            pr.copy(tracks = pr.tracks.map { t -> if (t.id != trackId) t else t.copy(clips = t.clips.filter { it.id != clipId }) })
        }
        file?.let { store.deleteUnreferenced(setOf(it), project!!) }
    }

    // MARK: ajustes

    fun setBpm(v: Double) {
        update { it.copy(bpm = v.coerceIn(30.0, 250.0)) }
        project?.let { native?.setClick(it.bpm, it.beatsPerBar, clickEnabled) }
    }

    fun setBeatsPerBar(v: Int) {
        update { it.copy(beatsPerBar = v) }
        project?.let { native?.setClick(it.bpm, it.beatsPerBar, clickEnabled) }
    }

    fun changeClick(on: Boolean) {
        clickEnabled = on
        prefs.edit().putBoolean("studioClick", on).apply()
        project?.let { native?.setClick(it.bpm, it.beatsPerBar, on) }
    }

    fun changeCountIn(bars: Int) {
        countInBars = bars.coerceIn(0, 2)
        prefs.edit().putInt("studioCountIn", countInBars).apply()
    }

    fun changeInputGain(db: Float) {
        inputGainDb = db.coerceIn(-12f, 24f)
        prefs.edit().putFloat("studioGain", inputGainDb).apply()
        native?.setInputGain(inputGainDb)
    }

    fun changeMonitor(on: Boolean) {
        monitorEnabled = on
        native?.setMonitor(on, monitorEffects.toJson(ampPath(monitorEffects)).toString())
    }

    fun changeMonitorEffects(e: EffectSettings) {
        monitorEffects = e
        native?.setMonitor(monitorEnabled, e.toJson(ampPath(e)).toString())
    }

    fun changeLatencyAdjust(ms: Float) {
        latencyAdjustMs = ms.coerceIn(-200f, 200f)
        prefs.edit().putFloat("studioLatencyAdjust", latencyAdjustMs).apply()
    }

    fun measuredLatencyMs(): Double = native?.latencyMs() ?: 0.0

    // MARK: amps (.nam)

    fun amps(): List<String> = (store.ampsDir.listFiles() ?: emptyArray()).filter { it.name.endsWith(".nam") }.map { it.name }.sorted()

    fun importAmp(uri: Uri, onDone: (String?) -> Unit) {
        scope.launch {
            val name = withContext(Dispatchers.IO) {
                try {
                    val n = displayName(uri)?.takeIf { it.endsWith(".nam", true) } ?: "amp-${System.currentTimeMillis()}.nam"
                    store.ampsDir.mkdirs()
                    app.contentResolver.openInputStream(uri)?.use { i -> File(store.ampsDir, n).outputStream().use { i.copyTo(it) } }
                    n
                } catch (e: Exception) {
                    lastError = "Não consegui importar o amplificador: ${e.message}"
                    null
                }
            }
            onDone(name)
        }
    }

    // MARK: importar e exportar

    private fun displayName(uri: Uri): String? = try {
        app.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    } catch (_: Exception) {
        null
    } ?: uri.lastPathSegment?.substringAfterLast('/')

    /** Copia um áudio (de outro app ou do Treino) para o projeto como uma faixa nova. */
    suspend fun importAudio(uri: Uri, name: String? = null): StudioTrack? {
        val p = project ?: return null
        busy = "Importando…"
        try {
            val title = name ?: displayName(uri)?.substringBeforeLast('.') ?: "Áudio"
            val fileName = "import-${UUID.randomUUID()}.pcm"
            val dest = store.file(p.id, fileName).also { it.parentFile?.mkdirs() }
            val frames = withContext(Dispatchers.IO) {
                AudioDecoder.decodeToPcm(app, uri, dest, targetRate = STUDIO_RATE).also { Waveforms.compute(dest) }
            }
            val seconds = frames.toDouble() / STUDIO_RATE
            if (seconds < 0.1) { dest.delete(); lastError = "O arquivo não tem áudio."; return null }
            val t = StudioTrack(name = title, isImported = true, clips = listOf(StudioClip(fileName = fileName, offset = 0.0, duration = seconds)))
            update(structural = true) { it.copy(tracks = it.tracks + t) }
            return t
        } catch (e: Exception) {
            lastError = "Não consegui importar: ${e.message ?: e.javaClass.simpleName}"
            return null
        } finally {
            busy = null
        }
    }

    fun importAudioAsync(uri: Uri) {
        scope.launch { importAudio(uri) }
    }

    /** Mixa tudo (com efeitos) e grava em m4a ou wav; devolve o arquivo pronto para compartilhar. */
    suspend fun exportMix(wav: Boolean): File? {
        val p = project ?: return null
        if (p.duration <= 0) { lastError = "Grave ou importe algo antes de exportar."; return null }
        if (transport != Transport.STOPPED) stop()
        busy = "Exportando…"
        try {
            return withContext(Dispatchers.Default) {
                val outDir = File(app.cacheDir, "export").also { it.mkdirs(); it.listFiles()?.forEach { f -> f.delete() } }
                val safe = p.name.replace(Regex("[^\\p{L}\\p{N} ._-]"), "").trim().ifEmpty { "Pestana" }
                val pcm = File(outDir, "mix.pcm")
                val frames = ((p.duration + 2.5) * STUDIO_RATE).roundToLong() // +2,5 s de rabo do reverb/delay
                NativeStudio.nRenderOffline(songJson(p), pcm.path, frames)?.let { throw IllegalStateException(it) }
                val out = File(outDir, if (wav) "$safe.wav" else "$safe.m4a")
                if (wav) writeWav(pcm, out) else PcmFile(pcm, STUDIO_RATE).use { AacEncoder.encode(it, out, bitrate = 256_000) }
                pcm.delete()
                out
            }
        } catch (e: Exception) {
            lastError = "Não consegui exportar: ${e.message ?: e.javaClass.simpleName}"
            return null
        } finally {
            busy = null
        }
    }

    private fun writeWav(pcm: File, out: File) {
        val dataLen = pcm.length()
        RandomAccessFile(out, "rw").use { f ->
            f.setLength(0)
            val h = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            h.put("RIFF".toByteArray()).putInt((36 + dataLen).toInt()).put("WAVE".toByteArray())
            h.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(2).putInt(STUDIO_RATE).putInt(STUDIO_RATE * 4)
                .putShort(4).putShort(16)
            h.put("data".toByteArray()).putInt(dataLen.toInt())
            f.write(h.array())
            pcm.inputStream().use { i ->
                val buf = ByteArray(1 shl 16)
                while (true) { val n = i.read(buf); if (n < 0) break; f.write(buf, 0, n) }
            }
        }
    }

    fun release() {
        deactivate()
    }
}
