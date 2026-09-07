package info.epidemica.proximity

import io.flutter.plugin.common.EventChannel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * How the two kinds of event reach Dart, and why they are not the same kind.
 *
 * A detection is evidence and is buffered until something is listening. A wake is a notice that the
 * process is running, worth nothing to a listener that is not there — and buffering it would cost a
 * detection its place, which the record reports as lost observation.
 */
class ProximityEventsTest {

    private class RecordingSink : EventChannel.EventSink {
        val events = mutableListOf<Any?>()

        override fun success(event: Any?) {
            events.add(event)
        }

        override fun error(code: String, message: String?, details: Any?) = Unit

        override fun endOfStream() = Unit
    }

    @After
    fun tearDown() {
        ProximityEvents.detach()
        ProximityEvents.drainForTest()
    }

    @Test
    fun `an offer with nobody listening is dropped rather than buffered`() {
        ProximityEvents.detach()
        ProximityEvents.drainForTest()

        repeat(10_000) { ProximityEvents.offer(mapOf("type" to "wake")) }

        // The detection buffer holds 8192. Ten thousand buffered wakes would have evicted every
        // detection in it and reported the loss as missing observation.
        assertEquals(0, ProximityEvents.bufferedForTest())
    }

    @Test
    fun `a detection with nobody listening is kept`() {
        ProximityEvents.detach()
        ProximityEvents.drainForTest()

        ProximityEvents.emit(mapOf("type" to "detection", "observed_at_ms" to 1L))

        assertEquals(1, ProximityEvents.bufferedForTest())
    }

    @Test
    fun `an offer does not disturb detections waiting to be delivered`() {
        ProximityEvents.detach()
        ProximityEvents.drainForTest()

        ProximityEvents.emit(mapOf("type" to "detection", "observed_at_ms" to 1L))
        repeat(100) { ProximityEvents.offer(mapOf("type" to "wake")) }

        val drained = ProximityEvents.drainForTest()
        assertEquals(1, drained.events.size)
        assertEquals(0, drained.dropped)
        assertTrue(drained.events.all { it["type"] == "detection" })
    }
}
