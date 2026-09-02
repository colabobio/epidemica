import XCTest

@testable import ProximityWire

/// Holds the Swift codec to the same wire vectors the Kotlin implementation uses.
final class ProximityPayloadTests: XCTestCase {

    private struct Vectors: Decodable {
        struct Roundtrip: Decodable {
            let `case`: String
            let pseudonym: String
            let device_class: String
            let hex: String
        }
        struct DecodeCase: Decodable {
            let `case`: String
            let pseudonym: String
            let device_class: String
            let hex: String
        }
        struct RejectCase: Decodable {
            let `case`: String
            let hex: String
        }
        let format_version: Int
        let size_bytes: Int
        let roundtrip: [Roundtrip]
        let decodes: [DecodeCase]
        let rejects: [RejectCase]
    }

    private lazy var vectors: Vectors = {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent(
                "contracts/wire/proximity_payload/1.0.0.vectors.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                // swiftlint:disable:next force_try
                return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: candidate))
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("could not locate the wire vectors from \(FileManager.default.currentDirectoryPath)")
    }()

    private func bytes(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func deviceClass(_ raw: String) -> String? {
        raw == "unknown" ? nil : raw
    }

    func testAgreesWithVectorsOnSizeAndVersion() {
        XCTAssertEqual(ProximityPayload.sizeBytes, vectors.size_bytes)
        XCTAssertEqual(Int(ProximityPayload.formatVersion), vectors.format_version)
    }

    func testEncodesAndDecodesEveryRoundtripVector() {
        XCTAssertFalse(vectors.roundtrip.isEmpty, "no roundtrip vectors found")

        for vector in vectors.roundtrip {
            let encoded = ProximityPayload.encode(
                pseudonym: vector.pseudonym,
                deviceClass: deviceClass(vector.device_class))
            XCTAssertEqual(hex(encoded ?? Data()), vector.hex, "encode: \(vector.case)")

            let decoded = ProximityPayload.decode(bytes(vector.hex))
            XCTAssertEqual(decoded?.pseudonym, vector.pseudonym, "decode: \(vector.case)")
            XCTAssertEqual(
                decoded?.deviceClass, deviceClass(vector.device_class), "class: \(vector.case)")
        }
    }

    func testDecodesToleratedVectors() {
        XCTAssertFalse(vectors.decodes.isEmpty, "no decode vectors found")

        for vector in vectors.decodes {
            let decoded = ProximityPayload.decode(bytes(vector.hex))
            XCTAssertNotNil(decoded, "should decode: \(vector.case)")
            XCTAssertEqual(decoded?.pseudonym, vector.pseudonym, vector.case)
            XCTAssertEqual(decoded?.deviceClass, deviceClass(vector.device_class), vector.case)
        }
    }

    func testRejectsEveryRejectVector() {
        XCTAssertFalse(vectors.rejects.isEmpty, "no reject vectors found")

        for vector in vectors.rejects {
            XCTAssertNil(
                ProximityPayload.decode(bytes(vector.hex)), "should reject: \(vector.case)")
        }
    }

    func testRejectsNilRatherThanCrashing() {
        XCTAssertNil(ProximityPayload.decode(nil))
    }

    func testRefusesToEncodeSomethingThatIsNotAUuid() {
        XCTAssertNil(ProximityPayload.encode(pseudonym: "not-a-uuid", deviceClass: "ios"))
    }
}
