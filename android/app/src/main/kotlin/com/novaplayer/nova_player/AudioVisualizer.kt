package com.novaplayer.nova_player

import android.media.audiofx.Visualizer
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.min

/**
 * Streams [BANDS] loudness levels (0..1) of the player's output to Flutter,
 * about 20 times a second. Listening takes the player's audio session id.
 */
class AudioVisualizer : EventChannel.StreamHandler {
    private var visualizer: Visualizer? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val session = (arguments as? Number)?.toInt() ?: return events.endOfStream()
        try {
            visualizer = Visualizer(session).apply {
                captureSize = Visualizer.getCaptureSizeRange()[1].coerceAtMost(1024)
                setDataCaptureListener(object : Visualizer.OnDataCaptureListener {
                    override fun onWaveFormDataCapture(v: Visualizer, data: ByteArray, rate: Int) {}

                    override fun onFftDataCapture(v: Visualizer, fft: ByteArray, rate: Int) {
                        val levels = bands(fft)
                        main.post { events.success(levels) }
                    }
                }, Visualizer.getMaxCaptureRate(), false, true)
                enabled = true
            }
        } catch (e: Exception) {
            // No permission, or the session is gone: the player shows nothing.
            events.error("VISUALIZER", e.message, null)
        }
    }

    override fun onCancel(arguments: Any?) {
        visualizer?.let {
            it.enabled = false
            it.release()
        }
        visualizer = null
    }

    companion object {
        const val BANDS = 32

        /** Log-spaced bands, so bass and treble each get a fair share. */
        fun bands(fft: ByteArray): DoubleArray {
            val bins = fft.size / 2
            val out = DoubleArray(BANDS)
            for (band in 0 until BANDS) {
                val from = (Math.pow(bins.toDouble(), band.toDouble() / BANDS)).toInt().coerceAtLeast(1)
                val to = min(bins, Math.pow(bins.toDouble(), (band + 1.0) / BANDS).toInt().coerceAtLeast(from + 1))
                var peak = 0.0
                for (k in from until to) {
                    peak = maxOf(peak, hypot(fft[2 * k].toDouble(), fft[2 * k + 1].toDouble()))
                }
                // 0..~181 magnitude to 0..1 on a log scale, which matches hearing.
                out[band] = (ln(1 + peak) / ln(182.0)).coerceIn(0.0, 1.0)
            }
            return out
        }
    }
}
