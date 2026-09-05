import CoreBluetooth
import Foundation
import Herald
import ProximityWire
import os.log

/// Owns the Herald sensor for the lifetime of the process.
final class ProximitySensor: NSObject, SensorDelegate {

    static let shared = ProximitySensor()

    private static let log = OSLog(subsystem: "info.epidemica.proximity", category: "sensor")

    private var sensorArray: SensorArray?
    private var lastServiceUuid: String?

    /// False until this *process* has started sensing.
    ///
    /// The distinction matters because iOS relaunches the app for Bluetooth state restoration, and
    /// a `sensorArray` left over from the previous session points at a dead BLE stack. It looks
    /// alive and reports nothing, which is the worst kind of failure here — silent and total. This
    /// flag is what tells a genuine cold start apart from a restart.
    private var hasStartedThisSession = false

    var isRunning: Bool { sensorArray != nil }

    /// Last Bluetooth state Herald reported.
    ///
    /// Taken from `didUpdateState` rather than by instantiating a `CBCentralManager` here: a second
    /// manager would duplicate Herald's own and can trigger a power alert. Nil until Herald has
    /// said anything, and treated as off, because claiming observation we cannot demonstrate is
    /// the failure this exists to prevent.
    private var lastSensorState: SensorState?

    var isRadioEnabled: Bool { lastSensorState == .on }

    func start(pseudonym: String, serviceUuid: String) throws {
        if sensorArray != nil && !hasStartedThisSession {
            os_log("Discarding a sensor left over from a previous session", log: Self.log, type: .info)
            stop()
        }

        if let last = lastServiceUuid, last != serviceUuid, sensorArray != nil {
            os_log("Study changed; reinitialising", log: Self.log, type: .info)
            stop()
        }

        if sensorArray != nil { return }

        guard let supplier = EpidemicaPayloadSupplier(pseudonym: pseudonym) else {
            throw ProximityError.invalidPseudonym
        }
        guard let uuid = UUID(uuidString: serviceUuid) else {
            throw ProximityError.invalidServiceUuid
        }

        BLESensorConfiguration.payloadDataUpdateTimeInterval = TimeInterval.minute
        BLESensorConfiguration.customServiceUUID = CBUUID(nsuuid: uuid)
        BLESensorConfiguration.customServiceDetectionEnabled = true
        BLESensorConfiguration.customServiceAdvertisingEnabled = true
        // Herald enables a CoreLocation "mobility sensor" by default, which turns on background
        // location updates. It crashes any app that has not declared the `location` background
        // mode, and on one that has, it quietly collects location — which this study promises not
        // to do and Android is explicitly configured against. Off, on purpose. Herald for Android
        // has no equivalent, which is why only iOS was affected.
        BLESensorConfiguration.mobilitySensorEnabled = nil
        // Study scoping: with the standard Herald service off, devices in other studies — and other
        // Herald apps entirely — are neither seen nor visible.
        BLESensorConfiguration.standardHeraldServiceDetectionEnabled = false
        BLESensorConfiguration.standardHeraldServiceAdvertisingEnabled = false

        let array = SensorArray(supplier)
        array.add(delegate: self)
        array.start()

        sensorArray = array
        lastServiceUuid = serviceUuid
        hasStartedThisSession = true
        ProximityEvents.shared.emit(["type": "started"])
    }

    func stop() {
        sensorArray?.stop()
        sensorArray = nil
    }

    // MARK: - SensorDelegate

    /// The only callback used. The payload-only and proximity-only callbacks cannot be turned into
    /// a detection without guessing at the other half.
    func sensor(
        _ sensor: SensorType, didMeasure: Proximity, fromTarget: TargetIdentifier,
        withPayload: PayloadData
    ) {
        guard let rssi = didMeasure.value as Double?,
            let decoded = ProximityPayload.decode(withPayload.data)
        else { return }

        var event: [String: Any] = [
            "type": "detection",
            "peer": decoded.pseudonym,
            "rssi": rssi,
            // Stamped here, not on arrival in Dart: iOS batches background delivery, and the error
            // would land on exactly the long background encounters that matter most.
            "observed_at_ms": Int64(Date().timeIntervalSince1970 * 1000),
        ]
        event["peer_device_class"] = decoded.deviceClass
        ProximityEvents.shared.emit(event)

        // A background wake is the only execution time this app gets when the screen is off, so
        // it is also the only opportunity to offer a sync. The Dart side applies its own floor, so
        // offering on every detection cannot actually fire more often than that floor allows.
        ProximityEvents.shared.emit(["type": "sync_due"])
    }

    func sensor(_ sensor: SensorType, didDetect: TargetIdentifier) {}
    func sensor(_ sensor: SensorType, didRead: PayloadData, fromTarget: TargetIdentifier) {}
    func sensor(_ sensor: SensorType, didReceive: Data, fromTarget: TargetIdentifier) {}
    func sensor(_ sensor: SensorType, didMeasure: Proximity, fromTarget: TargetIdentifier) {}
    func sensor(_ sensor: SensorType, didVisit: Location?) {}
    func sensor(_ sensor: SensorType, didShare: [PayloadData], fromTarget: TargetIdentifier) {}

    func sensor(_ sensor: SensorType, didUpdateState: SensorState) {
        lastSensorState = didUpdateState
    }
}

enum ProximityError: Error {
    case invalidPseudonym
    case invalidServiceUuid
}
