package com.novaplayer.nova_player

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import java.io.File
import java.nio.ByteOrder
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import kotlin.math.sqrt

/** Real loudness bars for a song, decoded in parallel segments and cached. */
object Waveform {
    private val cores = Runtime.getRuntime().availableProcessors().coerceIn(2, 4)
    private val segmentPool = Executors.newFixedThreadPool(cores)

    /** [bins] bar heights in 0..1, or null when the file can't be decoded. */
    fun bars(context: Context, uri: Uri, key: String, bins: Int): List<Double>? {
        val cache = File(File(context.filesDir, "waveforms").apply { mkdirs() }, "$key-$bins")
        if (cache.length() == bins.toLong()) {
            return cache.readBytes().map { (it.toInt() and 0xff) / 255.0 }
        }
        val durationUs = audioTrack(context, uri)?.second
            ?.takeIf { it.containsKey(MediaFormat.KEY_DURATION) }
            ?.getLong(MediaFormat.KEY_DURATION)
            ?.takeIf { it > 0 } ?: return null

        // Each segment sums squares into its own arrays; stitching just adds them.
        val step = durationUs / cores
        val parts = segmentPool.invokeAll((0 until cores).map { i ->
            Callable {
                val end = if (i == cores - 1) Long.MAX_VALUE else step * (i + 1)
                decodeSegment(context, uri, step * i, end, durationUs, bins)
            }
        }).map { it.get() ?: return null }
        val sums = DoubleArray(bins)
        val counts = LongArray(bins)
        for ((partSums, partCounts) in parts) {
            for (b in 0 until bins) {
                sums[b] += partSums[b]
                counts[b] += partCounts[b]
            }
        }
        val rms = DoubleArray(bins) { if (counts[it] == 0L) 0.0 else sqrt(sums[it] / counts[it]) }
        val loudest = rms.maxOrNull()?.takeIf { it > 0 } ?: return null
        // A floor keeps silent stretches visible as thin bars.
        val bars = rms.map { 0.08 + 0.92 * (it / loudest) }
        cache.writeBytes(ByteArray(bins) { (bars[it] * 255).toInt().toByte() })
        return bars
    }

    private fun audioTrack(context: Context, uri: Uri): Pair<Int, MediaFormat>? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(context, uri, null)
            (0 until extractor.trackCount)
                .map { it to extractor.getTrackFormat(it) }
                .firstOrNull { it.second.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
        } catch (_: Exception) {
            null
        } finally {
            extractor.release()
        }
    }

    /** Sum of squared samples and sample count per bin, for [startUs, endUs). */
    private fun decodeSegment(
        context: Context, uri: Uri, startUs: Long, endUs: Long, durationUs: Long, bins: Int,
    ): Pair<DoubleArray, LongArray>? {
        val sums = DoubleArray(bins)
        val counts = LongArray(bins)
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(context, uri, null)
            val (track, format) = (0 until extractor.trackCount)
                .map { it to extractor.getTrackFormat(it) }
                .firstOrNull { it.second.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
                ?: return null
            extractor.selectTrack(track)
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(format, null, null, 0)
            codec.start()

            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var encoding = AudioFormat.ENCODING_PCM_16BIT
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            while (true) {
                if (!inputDone) {
                    val index = codec.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        val size = extractor.readSampleData(codec.getInputBuffer(index)!!, 0)
                        val time = extractor.sampleTime
                        if (size < 0 || time >= endUs) {
                            codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(index, 0, size, time, 0)
                            extractor.advance()
                        }
                    }
                }
                val index = codec.dequeueOutputBuffer(info, 10_000)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val out = codec.outputFormat
                    channels = out.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    sampleRate = out.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    if (out.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                        encoding = out.getInteger(MediaFormat.KEY_PCM_ENCODING)
                    }
                } else if (index >= 0) {
                    val buffer = codec.getOutputBuffer(index)!!.order(ByteOrder.nativeOrder())
                    buffer.position(info.offset).limit(info.offset + info.size)
                    val samples: (Int) -> Double = when (encoding) {
                        AudioFormat.ENCODING_PCM_FLOAT -> {
                            val floats = buffer.asFloatBuffer(); { floats[it].toDouble() }
                        }
                        AudioFormat.ENCODING_PCM_16BIT -> {
                            val shorts = buffer.asShortBuffer(); { shorts[it] / 32768.0 }
                        }
                        else -> return null
                    }
                    val bytesPerSample = if (encoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
                    val frames = info.size / bytesPerSample / channels
                    for (frame in 0 until frames) {
                        val time = info.presentationTimeUs + frame * 1_000_000L / sampleRate
                        // Decoding starts at the sync frame before startUs; skip that lead-in.
                        if (time < startUs || time >= endUs) continue
                        val bin = (time * bins / durationUs).toInt().coerceIn(0, bins - 1)
                        for (channel in 0 until channels) {
                            val sample = samples(frame * channels + channel)
                            sums[bin] += sample * sample
                        }
                        counts[bin] += channels.toLong()
                    }
                    codec.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
            return sums to counts
        } catch (_: Exception) {
            return null
        } finally {
            codec?.let { runCatching { it.stop() }; it.release() }
            extractor.release()
        }
    }
}
