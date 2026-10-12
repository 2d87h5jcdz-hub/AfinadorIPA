package com.pestana.estudio.audio

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import com.pestana.estudio.core.Resampler
import java.io.File
import java.io.IOException
import java.nio.ByteOrder

/** Decodifica MP3/M4A/AAC/WAV/OGG/FLAC (o que o Android souber) para PCM estéreo (44,1 ou 48 kHz). */
object AudioDecoder {

    class Info(val sampleRate: Int, val channels: Int, val durationUs: Long)

    /**
     * Decodifica [uri] (ou arquivo) e grava em [dest] no formato do [PcmFile].
     * @return quadros gravados.
     */
    fun decodeToPcm(
        context: Context,
        uri: Uri,
        dest: File,
        progress: (Double) -> Unit = {},
        cancelled: () -> Boolean = { false },
        targetRate: Int = PcmFile.SAMPLE_RATE,
    ): Long {
        val tmp = File(dest.parentFile, dest.name + ".part")
        tmp.parentFile?.mkdirs()
        PcmWriter(tmp).use { w ->
            var resampler: Resampler? = null
            decode(context, uri, progress, cancelled,
                onFormat = { info -> resampler = Resampler(info.sampleRate, targetRate) },
                sink = { l, r, n -> resampler!!.process(l, r, n) { ol, or, k -> w.write(ol, or, k) } },
            )
            resampler?.finish { ol, or, k -> w.write(ol, or, k) }
        }
        if (!tmp.renameTo(dest)) throw IOException("não consegui gravar ${dest.name}")
        return dest.length() / PcmFile.BYTES_PER_FRAME
    }

    fun decode(
        context: Context,
        uri: Uri,
        progress: (Double) -> Unit,
        cancelled: () -> Boolean,
        onFormat: (Info) -> Unit,
        sink: (FloatArray, FloatArray, Int) -> Unit,
    ) {
        val ex = MediaExtractor()
        try {
            if (uri.scheme == null || uri.scheme == "file") ex.setDataSource(uri.path!!)
            else ex.setDataSource(context, uri, null)
            var track = -1
            for (i in 0 until ex.trackCount) {
                val mime = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) { track = i; break }
            }
            if (track < 0) throw IOException("o arquivo não tem áudio")
            ex.selectTrack(track)
            val fmt = ex.getTrackFormat(track)
            val mime = fmt.getString(MediaFormat.KEY_MIME)!!
            val durationUs = if (fmt.containsKey(MediaFormat.KEY_DURATION)) fmt.getLong(MediaFormat.KEY_DURATION) else 0L
            val codec = MediaCodec.createDecoderByType(mime)
            codec.configure(fmt, null, null, 0)
            codec.start()
            try {
                loop(ex, codec, durationUs, progress, cancelled, onFormat, sink)
            } finally {
                try { codec.stop() } catch (_: Exception) {}
                codec.release()
            }
        } finally {
            ex.release()
        }
    }

    private fun loop(
        ex: MediaExtractor,
        codec: MediaCodec,
        durationUs: Long,
        progress: (Double) -> Unit,
        cancelled: () -> Boolean,
        onFormat: (Info) -> Unit,
        sink: (FloatArray, FloatArray, Int) -> Unit,
    ) {
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var channels = 2
        var floatPcm = false
        var formatKnown = false
        var l = FloatArray(4096)
        var r = FloatArray(4096)
        var lastProgress = -1.0
        while (true) {
            if (cancelled()) throw InterruptedException("cancelado")
            if (!inputDone) {
                val inIdx = codec.dequeueInputBuffer(10_000)
                if (inIdx >= 0) {
                    val buf = codec.getInputBuffer(inIdx)!!
                    val size = ex.readSampleData(buf, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(inIdx, 0, size, ex.sampleTime, 0)
                        ex.advance()
                    }
                }
            }
            val outIdx = codec.dequeueOutputBuffer(info, 10_000)
            if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED || (outIdx >= 0 && !formatKnown)) {
                val of = codec.outputFormat
                channels = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                floatPcm = of.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                    of.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                if (!formatKnown) {
                    onFormat(Info(of.getInteger(MediaFormat.KEY_SAMPLE_RATE), channels, durationUs))
                    formatKnown = true
                }
            }
            if (outIdx >= 0) {
                val buf = codec.getOutputBuffer(outIdx)!!.order(ByteOrder.LITTLE_ENDIAN)
                buf.position(info.offset)
                buf.limit(info.offset + info.size)
                val bytesPerSample = if (floatPcm) 4 else 2
                val frames = info.size / (bytesPerSample * channels)
                if (frames > l.size) { l = FloatArray(frames); r = FloatArray(frames) }
                if (floatPcm) {
                    val fb = buf.asFloatBuffer()
                    for (i in 0 until frames) {
                        l[i] = fb.get(i * channels)
                        r[i] = if (channels > 1) fb.get(i * channels + 1) else l[i]
                    }
                } else {
                    val sb = buf.asShortBuffer()
                    for (i in 0 until frames) {
                        l[i] = sb.get(i * channels) / 32768f
                        r[i] = if (channels > 1) sb.get(i * channels + 1) / 32768f else l[i]
                    }
                }
                if (frames > 0) sink(l, r, frames)
                codec.releaseOutputBuffer(outIdx, false)
                if (durationUs > 0) {
                    val p = (info.presentationTimeUs.toDouble() / durationUs).coerceIn(0.0, 1.0)
                    if (p - lastProgress > 0.01) { progress(p); lastProgress = p }
                }
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
        }
    }
}
