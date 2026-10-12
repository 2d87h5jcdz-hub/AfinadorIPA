package com.pestana.estudio.audio

/**
 * Contratos de entrada/saída de áudio. Hoje a implementação é AudioRecord/AudioTrack
 * (AudioTrackOutput, AudioRecordInput); quando chegar o Estúdio (gravação multipista),
 * basta criar versões com Oboe (C++/NDK) que cumpram estas mesmas interfaces — os
 * geradores de som (core/Synth.kt) e as telas não mudam.
 */
interface AudioOutput {
    val sampleRate: Int

    /** Liga o stream (se ainda não estiver ligado). */
    fun start()

    /** Desliga o stream e libera o dispositivo de áudio. */
    fun stop()

    /** Amostras já tocadas no alto-falante desde que o stream atual ligou. */
    fun playedFrames(): Long

    val isRunning: Boolean
}

interface AudioInput {
    val sampleRate: Int

    /**
     * Começa a captar o microfone e entrega blocos mono em float na thread de áudio.
     * @return false se o microfone não pôde ser aberto.
     */
    fun start(onBlock: (FloatArray, Int) -> Unit): Boolean

    fun stop()

    val isRunning: Boolean
}
