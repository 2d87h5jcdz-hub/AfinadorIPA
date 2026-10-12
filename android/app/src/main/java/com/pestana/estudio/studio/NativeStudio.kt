package com.pestana.estudio.studio

/** Ponte para o motor C++/Oboe (app/src/main/cpp). Um objeto por app. */
class NativeStudio {
    companion object {
        init {
            System.loadLibrary("pestana_studio")
        }

        @JvmStatic external fun nRenderOffline(json: String, outPath: String, frames: Long): String?
    }

    private val h = nCreate()

    fun open(withInput: Boolean): String? = nOpen(h, withInput)
    fun close() = nClose(h)
    fun hasInput() = nHasInput(h)
    fun setSong(json: String): String? = nSetSong(h, json)
    fun setTrackMix(id: Long, volume: Float, pan: Float, mute: Boolean, solo: Boolean, fxOn: Boolean) =
        nSetTrackMix(h, id, volume, pan, mute, solo, fxOn)
    fun setTrackFx(id: Long, json: String) = nSetTrackFx(h, id, json)
    fun setMonitor(on: Boolean, fxJson: String) = nSetMonitor(h, on, fxJson)
    fun setInputGain(db: Float) = nSetInputGain(h, db)
    fun setClick(bpm: Double, beatsPerBar: Int, on: Boolean) = nSetClick(h, bpm, beatsPerBar, on)
    fun start(fromFrame: Long, leadIn: Long, recordPath: String?, silenced: Long): String? =
        nStart(h, fromFrame, leadIn, recordPath, silenced)
    fun stop(): Long = nStop(h)
    /** [estado, quadro da música, quadros gravados] */
    fun status(): LongArray = nStatus(h)
    /** [entrada, faixa 0, faixa 1, …] */
    fun levels(): FloatArray = nLevels(h)
    fun latencyMs(): Double = nLatencyMs(h)

    private external fun nCreate(): Long
    private external fun nDestroy(h: Long)
    private external fun nOpen(h: Long, withInput: Boolean): String?
    private external fun nClose(h: Long)
    private external fun nHasInput(h: Long): Boolean
    private external fun nSetSong(h: Long, json: String): String?
    private external fun nSetTrackMix(h: Long, id: Long, vol: Float, pan: Float, mute: Boolean, solo: Boolean, fxOn: Boolean)
    private external fun nSetTrackFx(h: Long, id: Long, json: String)
    private external fun nSetMonitor(h: Long, on: Boolean, json: String)
    private external fun nSetInputGain(h: Long, db: Float)
    private external fun nSetClick(h: Long, bpm: Double, bpb: Int, on: Boolean)
    private external fun nStart(h: Long, from: Long, lead: Long, path: String?, silenced: Long): String?
    private external fun nStop(h: Long): Long
    private external fun nStatus(h: Long): LongArray
    private external fun nLevels(h: Long): FloatArray
    private external fun nLatencyMs(h: Long): Double
}
