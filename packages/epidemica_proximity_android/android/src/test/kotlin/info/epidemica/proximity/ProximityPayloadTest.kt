package info.epidemica.proximity

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Holds the Kotlin codec to the shared wire vectors.
 *
 * Swift decodes the same file. Two implementations that can only ever meet on real hardware are
 * otherwise free to disagree about byte order, sign extension or trailing data, and the symptom
 * would be an iOS device and an Android device sitting next to each other detecting nothing.
 */
class ProximityPayloadTest {

    private val vectors: JSONObject by lazy {
        JSONObject(vectorsFile().readText())
    }

    private fun vectorsFile(): File {
        var dir: File? = File(System.getProperty("user.dir")!!).absoluteFile
        while (dir != null) {
            val candidate = File(dir, "contracts/wire/proximity_payload/1.0.0.vectors.json")
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("could not locate the wire vectors from ${System.getProperty("user.dir")}")
    }

    private fun hexToBytes(hex: String): ByteArray =
        ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun bytesToHex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }

    @Test
    fun `agrees with the shared vectors on size and version`() {
        assertEquals(ProximityPayload.SIZE_BYTES, vectors.getInt("size_bytes"))
        assertEquals(ProximityPayload.FORMAT_VERSION, vectors.getInt("format_version"))
    }

    @Test
    fun `encodes and decodes every roundtrip vector`() {
        val cases = vectors.getJSONArray("roundtrip")
        assertTrue("no roundtrip vectors found", cases.length() > 0)

        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val name = case.getString("case")
            val pseudonym = case.getString("pseudonym")
            val deviceClass = case.getString("device_class").takeIf { it != "unknown" }

            assertEquals(
                "encode: $name",
                case.getString("hex"),
                bytesToHex(ProximityPayload.encode(pseudonym, deviceClass)),
            )

            val decoded = ProximityPayload.decode(hexToBytes(case.getString("hex")))
            assertNotNull("decode: $name", decoded)
            assertEquals("decode pseudonym: $name", pseudonym, decoded!!.pseudonym)
            assertEquals("decode class: $name", deviceClass, decoded.deviceClass)
        }
    }

    @Test
    fun `decodes the tolerated vectors`() {
        val cases = vectors.getJSONArray("decodes")
        assertTrue("no decode vectors found", cases.length() > 0)

        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val name = case.getString("case")
            val decoded = ProximityPayload.decode(hexToBytes(case.getString("hex")))
            assertNotNull("should decode: $name", decoded)
            assertEquals(name, case.getString("pseudonym"), decoded!!.pseudonym)
            assertEquals(
                name,
                case.getString("device_class").takeIf { it != "unknown" },
                decoded.deviceClass,
            )
        }
    }

    @Test
    fun `rejects every reject vector`() {
        val cases = vectors.getJSONArray("rejects")
        assertTrue("no reject vectors found", cases.length() > 0)

        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            assertNull(
                "should reject: ${case.getString("case")}",
                ProximityPayload.decode(hexToBytes(case.getString("hex"))),
            )
        }
    }

    @Test
    fun `rejects a null payload rather than throwing`() {
        assertNull(ProximityPayload.decode(null))
    }
}
