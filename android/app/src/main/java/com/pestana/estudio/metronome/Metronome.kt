package com.pestana.estudio.metronome

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.pestana.estudio.audio.AudioOutput
import com.pestana.estudio.audio.AudioTrackOutput
import com.pestana.estudio.core.ClickRenderer
import com.pestana.estudio.core.TapTempo
import com.pestana.estudio.core.Tempo
import kotlin.math.roundToInt

/**
 * Metrônomo: o clique é gerado amostra a amostra dentro do stream de áudio (ClickRenderer),
 * então o andamento é exato. A bolinha da tela acende quando a batida sai no alto-falante.
 */
class Metronome(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("pestana", Context.MODE_PRIVATE)
    private val rate = AudioTrackOutput.nativeSampleRate(context.applicationContext)
    private val clicks = ClickRenderer(rate.toDouble())
    private val out: AudioOutput = AudioTrackOutput(rate, clicks, stopWhenIdle = true)
    private val tapTempo = TapTempo()

    var bpm by mutableDoubleStateOf(prefs.getFloat("bpm", 90f).toDouble().coerceIn(Tempo.MIN_BPM, Tempo.MAX_BPM))
        private set
    var beatsPerBar by mutableIntStateOf(prefs.getInt("beats", 4).takeIf { b -> Tempo.signatures.any { it.beats == b } } ?: 4)
        private set
    var playing by mutableStateOf(false)
        private set
    var currentBeat by mutableIntStateOf(-1)
        private set

    init {
        clicks.setTempo(bpm, beatsPerBar)
    }

    val tempoName: String get() = Tempo.name(bpm)

    fun changeBpm(value: Double) {
        val v = value.roundToInt().toDouble().coerceIn(Tempo.MIN_BPM, Tempo.MAX_BPM)
        if (v == bpm) return
        bpm = v
        clicks.setTempo(bpm, beatsPerBar)
        prefs.edit().putFloat("bpm", v.toFloat()).apply()
    }

    fun changeBeats(beats: Int) {
        beatsPerBar = beats
        clicks.setTempo(bpm, beatsPerBar)
        prefs.edit().putInt("beats", beats).apply()
    }

    fun toggle() = if (playing) stop() else start()

    fun start() {
        clicks.setTempo(bpm, beatsPerBar)
        clicks.start()
        out.start()
        playing = true
    }

    fun stop() {
        clicks.stop()
        playing = false
        currentBeat = -1
    }

    fun tap() {
        tapTempo.tap(System.nanoTime())?.let { changeBpm(it) }
    }

    /** Chamado a cada quadro da tela: acende a batida que acabou de soar. */
    fun pollBeat() {
        if (!playing) return
        val played = out.playedFrames()
        while (true) {
            val e = clicks.events.peek() ?: break
            if (e.frame > played) break
            clicks.events.poll()
            currentBeat = e.beat
        }
    }

    fun release() {
        stop()
        out.stop()
    }
}
