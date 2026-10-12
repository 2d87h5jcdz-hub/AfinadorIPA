package com.pestana.estudio.core

import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.sin
import kotlin.random.Random

/**
 * Gera áudio em blocos. É chamado pela thread de áudio (hoje AudioTrack; no futuro Oboe)
 * e não depende de Android, para poder ser testado no computador.
 */
interface AudioRenderer {
    /**
     * Preenche [out] com [frames] quadros em float (−1…1): mono, ou estéreo intercalado
     * (L R L R…, frames × 2 amostras) quando o stream é estéreo.
     * @param startFrame número absoluto da primeira amostra deste bloco desde o início do stream.
     */
    fun render(out: FloatArray, frames: Int, startFrame: Long)

    /** true quando não há mais som a gerar (o stream pode ser desligado para poupar bateria). */
    val isIdle: Boolean get() = false
}

/** Tom de referência do afinador: seno + 2º harmônico, decaindo em ~2,2 s (igual ao iOS). */
class ToneRenderer(private val sampleRate: Double) : AudioRenderer {
    private val lock = Any()
    private var phase = 0.0
    private var freq = 0.0
    private var gain = 0.0
    private val decay = 0.001.pow(1.0 / (2.2 * sampleRate))

    fun play(frequency: Double) = synchronized(lock) {
        freq = frequency
        gain = 1.0
        phase = 0.0
    }

    override fun render(out: FloatArray, frames: Int, startFrame: Long) = synchronized(lock) {
        val inc = 2 * PI * freq / sampleRate
        for (i in 0 until frames) {
            val v = sin(phase) + 0.25 * sin(2 * phase)
            out[i] = (v * gain * 0.35).toFloat()
            phase += inc
            if (phase > 2 * PI) phase -= 2 * PI
            gain *= decay
        }
    }

    override val isIdle: Boolean get() = synchronized(lock) { gain < 1e-4 }
}

/** Som de violão dedilhado (Karplus-Strong), portado do ChordPlayer do iOS. */
class PluckRenderer(private val sampleRate: Double, private val random: Random = Random.Default) : AudioRenderer {
    private class Voice(val buffer: FloatArray, var index: Int, var delay: Int)

    private val lock = Any()
    private var voices: List<Voice> = emptyList()
    private var framesSinceTrigger = Long.MAX_VALUE / 2

    /** Toca as notas com 30 ms entre uma corda e a próxima (como uma palhetada). */
    fun strum(midis: List<Int>, a4: Double, spacingSeconds: Double = 0.03) {
        val newVoices = midis.mapIndexed { k, m ->
            val f = Pitch.hz(m, a4)
            val length = max(2, (sampleRate / f).toInt())
            val buf = FloatArray(length) { random.nextFloat() * 2f - 1f }
            // suaviza o ruído inicial para um ataque menos áspero
            for (j in 1 until length) buf[j] = 0.5f * (buf[j] + buf[j - 1])
            Voice(buf, 0, (k * spacingSeconds * sampleRate).toInt())
        }
        synchronized(lock) {
            voices = newVoices
            framesSinceTrigger = 0
        }
    }

    override fun render(out: FloatArray, frames: Int, startFrame: Long) = synchronized(lock) {
        val vs = voices
        for (i in 0 until frames) {
            var s = 0f
            for (v in vs) {
                if (v.delay > 0) {
                    v.delay--
                    continue
                }
                val count = v.buffer.size
                val idx = v.index
                val next = if (idx + 1 == count) 0 else idx + 1
                val o = v.buffer[idx]
                v.buffer[idx] = 0.4985f * (o + v.buffer[next])
                v.index = next
                s += o
            }
            out[i] = s * 0.22f
        }
        framesSinceTrigger += frames
    }

    /** Depois de 6 s a corda já se calou. */
    override val isIdle: Boolean get() = synchronized(lock) { framesSinceTrigger > sampleRate * 6 }
}

/**
 * Clique do metrônomo gerado dentro do próprio stream de áudio (sem timers): cada batida cai
 * na amostra exata, então o andamento não oscila mesmo com a interface ocupada.
 */
class ClickRenderer(private val sampleRate: Double) : AudioRenderer {
    /** Batida gerada na amostra [frame] do stream (para a interface acender a bolinha na hora certa). */
    data class BeatEvent(val beat: Int, val frame: Long)

    private val lock = Any()
    private var samplesPerBeat = sampleRate / 2
    private var beats = 4
    private var countdown = 0.0
    private var beatIndex = 0
    private var clickPos = Int.MAX_VALUE
    private var clickFreq = 1000.0
    private var clickAmp = 1.0
    private var active = false
    private val clickLength = (sampleRate * 0.035).toInt()

    val events = ConcurrentLinkedQueue<BeatEvent>()

    fun setTempo(bpm: Double, beatsPerBar: Int) = synchronized(lock) {
        // 6/8: o clique marca as colcheias (duas por pulso de semínima).
        samplesPerBeat = sampleRate * 60.0 / bpm * (if (beatsPerBar == 6) 0.5 else 1.0)
        beats = beatsPerBar
        if (beatIndex >= beats) beatIndex = 0
    }

    fun start() = synchronized(lock) {
        countdown = 0.0
        beatIndex = 0
        active = true
        events.clear()
    }

    fun stop() = synchronized(lock) {
        active = false
    }

    override fun render(out: FloatArray, frames: Int, startFrame: Long) = synchronized(lock) {
        for (i in 0 until frames) {
            if (active) {
                if (countdown <= 0) {
                    val b = beatIndex
                    val accent = b == 0
                    val medium = beats == 6 && b == 3
                    clickFreq = if (accent) 2000.0 else if (medium) 1500.0 else 1100.0
                    clickAmp = if (accent) 1.0 else if (medium) 0.75 else 0.55
                    clickPos = 0
                    countdown += samplesPerBeat
                    beatIndex = (b + 1) % max(1, beats)
                    events.add(BeatEvent(b, startFrame + i))
                }
                countdown -= 1
            }
            var value = 0f
            if (clickPos < clickLength) {
                val t = clickPos / sampleRate
                val env = exp(-t * 140.0)
                value = (sin(2 * PI * clickFreq * t) * env * clickAmp * 0.8).toFloat()
                clickPos++
            }
            out[i] = value
        }
    }

    override val isIdle: Boolean get() = synchronized(lock) { !active && clickPos >= clickLength }
}

/** Média dos últimos toques (até 5, zerando após 2 s parado) → BPM, como no iOS. */
class TapTempo {
    private val taps = ArrayDeque<Long>()

    /** @return o BPM calculado (30–250), ou null se ainda não há toques suficientes. */
    fun tap(nowNanos: Long): Double? {
        val last = taps.lastOrNull()
        if (last != null && nowNanos - last > 2_000_000_000L) taps.clear()
        taps.addLast(nowNanos)
        if (taps.size > 5) taps.removeFirst()
        if (taps.size < 2) return null
        val avg = (nowNanos - taps.first()) / 1e9 / (taps.size - 1)
        return Math.round(60 / avg).toDouble().coerceIn(30.0, 250.0)
    }
}

object Tempo {
    const val MIN_BPM = 30.0
    const val MAX_BPM = 250.0

    data class Signature(val label: String, val beats: Int)

    val signatures = listOf(
        Signature("2/4", 2), Signature("3/4", 3), Signature("4/4", 4), Signature("6/8", 6),
    )

    fun name(bpm: Double): String = when {
        bpm < 60 -> "Largo"
        bpm < 76 -> "Adagio"
        bpm < 108 -> "Andante"
        bpm < 120 -> "Moderato"
        bpm < 168 -> "Allegro"
        else -> "Presto"
    }
}
