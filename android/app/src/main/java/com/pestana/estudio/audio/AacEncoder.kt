package com.pestana.estudio.audio

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.io.IOException
import java.nio.ByteOrder

/** Comprime um [PcmFile] em .m4a (AAC-LC 192 kbps) para guardar sem ocupar muito espaço. */
object AacEncoder {
    fun encode(pcm: PcmFile, dest: File, bitrate: Int = 192_000, cancelled: () -> Boolean = { false }) {
        val tmp = File(dest.parentFile, dest.name + ".part")
        val sr = pcm.sampleRate
        val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sr, 2).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        codec.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        val muxer = MediaMuxer(tmp.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var track = -1
        var muxing = false
        val info = MediaCodec.BufferInfo()
        val l = FloatArray(4096)
        val r = FloatArray(4096)
        var pos = 0L
        var inputDone = false
        try {
            while (true) {
                if (cancelled()) throw InterruptedException("cancelado")
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        val buf = codec.getInputBuffer(inIdx)!!.order(ByteOrder.LITTLE_ENDIAN)
                        buf.clear()
                        val frames = minOf((buf.capacity() / 4).toLong(), 4096L, pcm.frames - pos).toInt()
                        val ptsUs = pos * 1_000_000L / sr
                        if (frames <= 0) {
                            codec.queueInputBuffer(inIdx, 0, 0, ptsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            pcm.read(pos, frames, l, r)
                            for (i in 0 until frames) {
                                buf.putShort((l[i] * 32767f).toInt().coerceIn(-32768, 32767).toShort())
                                buf.putShort((r[i] * 32767f).toInt().coerceIn(-32768, 32767).toShort())
                            }
                            codec.queueInputBuffer(inIdx, 0, frames * 4, ptsUs, 0)
                            pos += frames
                        }
                    }
                }
                val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    track = muxer.addTrack(codec.outputFormat)
                    muxer.start()
                    muxing = true
                } else if (outIdx >= 0) {
                    val out = codec.getOutputBuffer(outIdx)!!
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                    if (info.size > 0 && muxing) {
                        out.position(info.offset)
                        out.limit(info.offset + info.size)
                        muxer.writeSampleData(track, out, info)
                    }
                    codec.releaseOutputBuffer(outIdx, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        } finally {
            try { codec.stop() } catch (_: Exception) {}
            codec.release()
            try { if (muxing) muxer.stop() } catch (_: Exception) {}
            muxer.release()
        }
        if (!tmp.renameTo(dest)) throw IOException("não consegui gravar ${dest.name}")
    }
}
