package com.pestana.estudio.chords

import android.content.Context
import com.pestana.estudio.audio.AudioOutput
import com.pestana.estudio.audio.AudioTrackOutput
import com.pestana.estudio.core.ChordBook
import com.pestana.estudio.core.PluckRenderer
import com.pestana.estudio.core.Voicing

/** Toca o acorde como uma palhetada de violão (Karplus-Strong). */
class ChordPlayer(context: Context) {
    private val rate = AudioTrackOutput.nativeSampleRate(context.applicationContext)
    private val pluck = PluckRenderer(rate.toDouble())
    private val out: AudioOutput = AudioTrackOutput(rate, pluck, stopWhenIdle = true)

    fun play(voicing: Voicing, a4: Double) {
        pluck.strum(ChordBook.midiNotes(voicing), a4)
        out.start()
    }

    fun release() = out.stop()
}
