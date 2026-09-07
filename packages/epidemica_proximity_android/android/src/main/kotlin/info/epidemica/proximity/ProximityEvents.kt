package info.epidemica.proximity

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * The single point where native detections meet the Dart event stream.
 *
 * Everything goes through the buffer, even when Dart is attached. That removes the attach race
 * outright rather than papering over it: there is no window in which an event can be produced,
 * find no listener, and vanish.
 */
object ProximityEvents {

    private val buffer = DetectionBuffer()
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var sink: EventChannel.EventSink? = null

    fun attach(sink: EventChannel.EventSink) {
        this.sink = sink
        flush()
    }

    fun detach() {
        sink = null
    }

    fun emit(event: Map<String, Any?>) {
        buffer.add(event)
        flush()
    }

    /**
     * Deliver an event only if Dart is listening, and drop it otherwise.
     *
     * For events that carry no evidence, such as a background wake. Buffering one would cost a
     * detection its place in a fixed-capacity buffer, and an overflow there is reported as lost
     * observation -- so a stream of ephemeral notices would show up in the record as missing data.
     * A wake nobody is awake to hear is worth nothing anyway.
     */
    fun offer(event: Map<String, Any?>) {
        val target = sink ?: return
        main.post {
            if (sink !== target) return@post
            target.success(event)
        }
    }

    private fun flush() {
        val target = sink ?: return
        main.post {
            if (sink !== target) return@post
            val drained = buffer.drain()
            // Announced before the survivors, because it describes the gap that precedes them.
            if (drained.dropped > 0) {
                target.success(
                    mapOf(
                        "type" to "dropped",
                        "count" to drained.dropped,
                        "oldest_retained_ms" to drained.oldestRetainedMs,
                    ),
                )
            }
            for (event in drained.events) target.success(event)
        }
    }

    /** What is waiting for a listener. Exists so a test can tell `emit` from `offer`. */
    internal fun bufferedForTest(): Int = buffer.size()

    internal fun drainForTest(): DetectionBuffer.Drained = buffer.drain()
}
