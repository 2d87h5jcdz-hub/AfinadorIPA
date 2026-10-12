package com.pestana.estudio.tuner

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import com.pestana.estudio.audio.AudioInput
import com.pestana.estudio.audio.AudioOutput
import com.pestana.estudio.audio.AudioRecordInput
import com.pestana.estudio.audio.AudioTrackOutput
import com.pestana.estudio.core.Pitch
import com.pestana.estudio.core.SlidingWindow
import com.pestana.estudio.core.ToneRenderer
import com.pestana.estudio.core.TunerLogic
import com.pestana.estudio.core.TunerReading
import com.pestana.estudio.core.Tuning
import com.pestana.estudio.core.Yin
import kotlin.math.abs

/** Afinador: microfone → YIN → leitura; e o tom de referência ao segurar uma corda. */
class TunerEngine(context: Context) {
    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences("pestana", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())

    // Estado observado pela interface
    var running by mutableStateOf(false)
        private set
    /** O microfone não abriu (outro app usando, por exemplo). */
    var micError by mutableStateOf(false)
        private set
    var reading by mutableStateOf<TunerReading?>(null)
        private set
    var tunedStrings by mutableStateOf(emptySet<Int>())
        private set
    /** Aumenta a cada corda que fica afinada (a tela vibra o aparelho). */
    var tunedEvents by mutableIntStateOf(0)
        private set

    var tuning by mutableStateOf(Tuning.byName(prefs.getString("tuning", null)))
        private set
    var a4 by mutableStateOf(prefs.getFloat("a4", Pitch.A4_DEFAULT.toFloat()).toDouble().coerceIn(Pitch.A4_MIN, Pitch.A4_MAX))
        private set
    var autoMode by mutableStateOf(prefs.getBoolean("auto", true))
        private set
    var manualIndex by mutableIntStateOf(0)
        private set

    fun selectTuning(t: Tuning) {
        tuning = t
        tunedStrings = emptySet()
        prefs.edit().putString("tuning", t.name).apply()
    }

    fun changeA4(value: Double) {
        a4 = value.coerceIn(Pitch.A4_MIN, Pitch.A4_MAX)
        prefs.edit().putFloat("a4", a4.toFloat()).apply()
    }

    fun changeAutoMode(auto: Boolean) {
        autoMode = auto
        prefs.edit().putBoolean("auto", auto).apply()
    }

    fun selectString(index: Int) {
        manualIndex = index
    }

    // MARK: microfone e análise

    private val input: AudioInput = AudioRecordInput()
    private val logic = TunerLogic()
    private val window = 4096
    // ~47 leituras por segundo: o ponteiro recebe alvos novos com frequência e anda sem trancos.
    private val hop = 1024
    private val frames = SlidingWindow(window, hop)
    private val scratch = FloatArray(window)
    private var inTuneSinceNanos = -1L

    fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(appContext, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    fun start() {
        if (running || !hasPermission()) return
        frames.reset()
        logic.reset()
        val ok = input.start { block, n -> ingest(block, n) }
        micError = !ok
        running = ok
    }

    fun stop() {
        if (!running) return
        input.stop()
        running = false
        clearReading()
    }

    /** Thread do microfone: acumula amostras e roda o YIN a cada [hop]. */
    private fun ingest(block: FloatArray, n: Int) {
        frames.feed(block, n) { frame ->
            val f = Yin.detect(frame, input.sampleRate.toDouble(), scratch)
            main.post { handle(f) }
        }
    }

    private fun handle(f: Double?) {
        if (!running) return
        when (val r = logic.feed(f, tuning, a4, autoMode, manualIndex)) {
            TunerLogic.Result.Unchanged -> Unit
            TunerLogic.Result.Clear -> clearReading()
            is TunerLogic.Result.Reading -> show(r.reading)
        }
    }

    private fun show(r: TunerReading) {
        reading = r
        if (abs(r.cents) <= 5) {
            val now = System.nanoTime()
            if (inTuneSinceNanos < 0) {
                inTuneSinceNanos = now
            } else {
                val idx = r.stringIndex
                if (idx != null && now - inTuneSinceNanos > 700_000_000L && idx !in tunedStrings) {
                    tunedStrings = tunedStrings + idx
                    tunedEvents++
                }
            }
        } else {
            inTuneSinceNanos = -1
        }
    }

    private fun clearReading() {
        reading = null
        inTuneSinceNanos = -1
    }

    // MARK: tom de referência

    private val outRate = AudioTrackOutput.nativeSampleRate(appContext)
    private val tone = ToneRenderer(outRate.toDouble())
    private val toneOut: AudioOutput = AudioTrackOutput(outRate, tone, stopWhenIdle = true)

    fun playReference(index: Int) {
        tone.play(Pitch.hz(tuning.midi[index], a4))
        toneOut.start()
    }

    fun release() {
        stop()
        toneOut.stop()
    }
}
