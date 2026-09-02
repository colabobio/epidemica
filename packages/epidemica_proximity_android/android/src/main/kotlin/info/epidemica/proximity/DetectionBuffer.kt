package info.epidemica.proximity

/**
 * Bounded FIFO holding detections observed while Dart was not listening.
 *
 * iOS and Android both relaunch an app in the background for Bluetooth work, and the Flutter engine
 * may not be attached when the radio starts reporting. Dropping those detections would bias the
 * record in a specific direction — the loss lands on unattended background encounters, which are
 * exactly the long ones a transmission study is trying to measure — so they are buffered, and any
 * overflow is counted and reported rather than swallowed.
 *
 * Pure Kotlin: no Android types, so it is unit tested on the JVM.
 */
class DetectionBuffer(private val capacity: Int = DEFAULT_CAPACITY) {

    companion object {
        /**
         * Roughly a day of detections for a busy participant. Chosen so that overflow means
         * something has genuinely gone wrong rather than that the user went to a concert.
         */
        const val DEFAULT_CAPACITY = 8192
    }

    class Drained(
        val events: List<Map<String, Any?>>,
        val dropped: Int,
        val oldestRetainedMs: Long?,
    )

    private val entries = ArrayDeque<Map<String, Any?>>()
    private var dropped = 0

    init {
        require(capacity > 0) { "capacity must be positive" }
    }

    @Synchronized
    fun add(event: Map<String, Any?>) {
        while (entries.size >= capacity) {
            entries.removeFirst()
            dropped++
        }
        entries.addLast(event)
    }

    @Synchronized
    fun size(): Int = entries.size

    @Synchronized
    fun droppedCount(): Int = dropped

    /** Empties the buffer and resets the drop counter, which the caller now owns. */
    @Synchronized
    fun drain(): Drained {
        val events = entries.toList()
        val oldest = events.firstNotNullOfOrNull { it["observed_at_ms"] as? Long }
        val result = Drained(events, dropped, oldest)
        entries.clear()
        dropped = 0
        return result
    }
}
