import Foundation
import Herald
import ProximityWire

/// Supplies the 18 bytes this device advertises. Identity and hardware class, nothing else.
final class EpidemicaPayloadSupplier: PayloadDataSupplier {

    private let encoded: PayloadData

    init?(pseudonym: String) {
        guard let bytes = ProximityPayload.encode(pseudonym: pseudonym, deviceClass: "ios") else {
            return nil
        }
        encoded = PayloadData(bytes)
    }

    func payload(_ timestamp: PayloadTimestamp, device: Device?) -> PayloadData? { encoded }

    func payload(_ data: Data) -> [PayloadData] {
        // Herald asks us to split a concatenated read back into individual payloads. Fixed width
        // makes that arithmetic rather than parsing.
        let size = ProximityPayload.sizeBytes
        guard data.count >= size else { return [] }
        return stride(from: 0, to: data.count - size + 1, by: size).map {
            PayloadData(data.subdata(in: $0..<($0 + size)))
        }
    }
}
