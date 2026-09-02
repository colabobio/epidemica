import Foundation

/// The bytes two Epidemica devices exchange over Bluetooth.
///
/// Specified in `contracts/wire/proximity_payload/1.0.0.md` and held to the shared vectors in
/// `1.0.0.vectors.json`, which the Kotlin implementation decodes too. Two implementations that can
/// only ever meet on real hardware are otherwise free to disagree about byte order or trailing
/// data, and the symptom would be an iPhone and an Android phone sitting side by side, detecting
/// nothing, with no error anywhere.
public enum ProximityPayload {

    public static let formatVersion: UInt8 = 1
    public static let sizeBytes = 18

    private static let offsetVersion = 0
    private static let offsetPseudonym = 1
    private static let offsetDeviceClass = 17

    private static let deviceClassIOS: UInt8 = 0
    private static let deviceClassAndroid: UInt8 = 1
    private static let deviceClassUnknown: UInt8 = 255

    public struct Decoded: Equatable {
        public let pseudonym: String
        public let deviceClass: String?

        public init(pseudonym: String, deviceClass: String?) {
            self.pseudonym = pseudonym
            self.deviceClass = deviceClass
        }
    }

    public static func encode(pseudonym: String, deviceClass: String?) -> Data? {
        guard let identity = uuidToBytes(pseudonym) else { return nil }
        var out = Data(capacity: sizeBytes)
        out.append(formatVersion)
        out.append(contentsOf: identity)
        switch deviceClass {
        case "ios": out.append(deviceClassIOS)
        case "android": out.append(deviceClassAndroid)
        default: out.append(deviceClassUnknown)
        }
        return out
    }

    /// Nil when the payload is not one this build can read.
    public static func decode(_ data: Data?) -> Decoded? {
        // Trailing bytes are tolerated: a later version may append fields, and rejecting on
        // unexpected length would make this build blind to every device running that version.
        guard let data, data.count >= sizeBytes else { return nil }
        let bytes = [UInt8](data)
        guard bytes[offsetVersion] == formatVersion else { return nil }

        let pseudonym = uuidFromBytes(Array(bytes[offsetPseudonym..<(offsetPseudonym + 16)]))
        let deviceClass: String?
        switch bytes[offsetDeviceClass] {
        case deviceClassIOS: deviceClass = "ios"
        case deviceClassAndroid: deviceClass = "android"
        default: deviceClass = nil
        }
        return Decoded(pseudonym: pseudonym, deviceClass: deviceClass)
    }

    private static func uuidToBytes(_ uuid: String) -> [UInt8]? {
        guard let parsed = UUID(uuidString: uuid) else { return nil }
        let u = parsed.uuid
        return [
            u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
            u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
        ]
    }

    private static func uuidFromBytes(_ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let part = { (lower: Int, upper: Int) -> String in
            let start = hex.index(hex.startIndex, offsetBy: lower)
            let end = hex.index(hex.startIndex, offsetBy: upper)
            return String(hex[start..<end])
        }
        return "\(part(0, 8))-\(part(8, 12))-\(part(12, 16))-\(part(16, 20))-\(part(20, 32))"
    }
}
