package info.epidemica.proximity

import io.heraldprox.herald.sensor.Device
import io.heraldprox.herald.sensor.datatype.PayloadData
import io.heraldprox.herald.sensor.datatype.PayloadTimestamp
import io.heraldprox.herald.sensor.payload.DefaultPayloadDataSupplier

/** Supplies the 18 bytes this device advertises. Identity and hardware class, nothing else. */
class EpidemicaPayloadSupplier(private val pseudonym: String) : DefaultPayloadDataSupplier() {

    private val encoded: ByteArray = ProximityPayload.encode(pseudonym, "android")

    override fun payload(timestamp: PayloadTimestamp, device: Device?): PayloadData =
        PayloadData(encoded)
}
