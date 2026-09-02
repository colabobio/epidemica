package info.epidemica.proximity

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DetectionBufferTest {

    private fun detection(at: Long): Map<String, Any?> =
        mapOf("type" to "detection", "observed_at_ms" to at)

    @Test
    fun `holds detections until drained`() {
        val buffer = DetectionBuffer(capacity = 4)
        buffer.add(detection(1))
        buffer.add(detection(2))

        assertEquals(2, buffer.size())
        val drained = buffer.drain()

        assertEquals(2, drained.events.size)
        assertEquals(0, drained.dropped)
        assertEquals(1L, drained.oldestRetainedMs)
        assertEquals(0, buffer.size())
    }

    @Test
    fun `overflow discards the oldest and counts what was lost`() {
        val buffer = DetectionBuffer(capacity = 3)
        for (t in 1L..5L) buffer.add(detection(t))

        val drained = buffer.drain()

        assertEquals(3, drained.events.size)
        assertEquals("two detections should have been counted as lost", 2, drained.dropped)
        assertEquals("the survivors are the newest", 3L, drained.oldestRetainedMs)
    }

    @Test
    fun `draining transfers ownership of the drop count`() {
        val buffer = DetectionBuffer(capacity = 1)
        buffer.add(detection(1))
        buffer.add(detection(2))

        assertEquals(1, buffer.drain().dropped)
        assertEquals("a second drain must not report the same loss twice", 0, buffer.drain().dropped)
    }

    @Test
    fun `an empty drain reports nothing rather than failing`() {
        val drained = DetectionBuffer().drain()

        assertEquals(0, drained.events.size)
        assertEquals(0, drained.dropped)
        assertNull(drained.oldestRetainedMs)
    }

    @Test
    fun `survives concurrent writers`() {
        val buffer = DetectionBuffer(capacity = 10_000)
        val threads = (0 until 8).map { worker ->
            Thread {
                for (i in 0 until 500) buffer.add(detection(worker * 1000L + i))
            }
        }
        threads.forEach { it.start() }
        threads.forEach { it.join() }

        val drained = buffer.drain()
        assertEquals(4000, drained.events.size)
        assertEquals(0, drained.dropped)
    }
}
