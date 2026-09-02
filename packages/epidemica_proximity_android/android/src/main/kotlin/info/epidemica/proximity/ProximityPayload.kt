package info.epidemica.proximity

import java.util.Locale
import java.util.UUID

/**
 * The bytes two Epidemica devices exchange over Bluetooth.
 *
 * Specified in `contracts/wire/proximity_payload/1.0.0.md` and held to the shared vectors in
 * `1.0.0.vectors.json`, which the Swift implementation decodes too. Pure: no Herald types, no
 * Android types, so it runs as a plain JVM unit test.
 */
object ProximityPayload {

    const val FORMAT_VERSION = 1
    const val SIZE_BYTES = 18

    private const val OFFSET_VERSION = 0
    private const val OFFSET_PSEUDONYM = 1
    private const val OFFSET_DEVICE_CLASS = 17

    private const val DEVICE_CLASS_IOS = 0
    private const val DEVICE_CLASS_ANDROID = 1
    private const val DEVICE_CLASS_UNKNOWN = 255

    data class Decoded(val pseudonym: String, val deviceClass: String?)

    fun encode(pseudonym: String, deviceClass: String?): ByteArray {
        val out = ByteArray(SIZE_BYTES)
        out[OFFSET_VERSION] = FORMAT_VERSION.toByte()
        uuidToBytes(pseudonym).copyInto(out, OFFSET_PSEUDONYM)
        out[OFFSET_DEVICE_CLASS] = when (deviceClass) {
            "ios" -> DEVICE_CLASS_IOS
            "android" -> DEVICE_CLASS_ANDROID
            else -> DEVICE_CLASS_UNKNOWN
        }.toByte()
        return out
    }

    /** Null when the payload is not one this build can read. */
    fun decode(bytes: ByteArray?): Decoded? {
        // Trailing bytes are tolerated: a later version may append fields, and rejecting on
        // unexpected length would make this build blind to every device running that version.
        if (bytes == null || bytes.size < SIZE_BYTES) return null
        if (bytes[OFFSET_VERSION].toInt() and 0xff != FORMAT_VERSION) return null

        val pseudonym = uuidFromBytes(bytes, OFFSET_PSEUDONYM)
        val deviceClass = when (bytes[OFFSET_DEVICE_CLASS].toInt() and 0xff) {
            DEVICE_CLASS_IOS -> "ios"
            DEVICE_CLASS_ANDROID -> "android"
            else -> null
        }
        return Decoded(pseudonym, deviceClass)
    }

    private fun uuidToBytes(uuid: String): ByteArray {
        val parsed = UUID.fromString(uuid)
        val out = ByteArray(16)
        var high = parsed.mostSignificantBits
        var low = parsed.leastSignificantBits
        for (i in 7 downTo 0) {
            out[i] = (high and 0xff).toByte()
            high = high ushr 8
            out[i + 8] = (low and 0xff).toByte()
            low = low ushr 8
        }
        return out
    }

    private fun uuidFromBytes(bytes: ByteArray, offset: Int): String {
        val hex = StringBuilder(32)
        for (i in 0 until 16) {
            hex.append(String.format(Locale.ROOT, "%02x", bytes[offset + i].toInt() and 0xff))
        }
        return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-" +
            "${hex.substring(16, 20)}-${hex.substring(20, 32)}"
    }
}
