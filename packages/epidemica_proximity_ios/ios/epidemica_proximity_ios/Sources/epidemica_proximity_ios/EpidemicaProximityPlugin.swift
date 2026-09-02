import Flutter
import Foundation
import UIKit

public class EpidemicaProximityPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = EpidemicaProximityPlugin()
        let methods = FlutterMethodChannel(
            name: "info.epidemica.proximity/methods", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methods)
        FlutterEventChannel(
            name: "info.epidemica.proximity/events", binaryMessenger: registrar.messenger()
        ).setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            start(call, result)
        case "stop":
            ProximitySensor.shared.stop()
            result(nil)
        case "isRunning":
            result(ProximitySensor.shared.isRunning)
        case "isRadioEnabled":
            result(ProximitySensor.shared.isRadioEnabled)
        case "observerDeviceClass":
            result("ios")
        case "missingPlatformRequirements":
            result(Self.missingPlatformRequirements())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func start(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let pseudonym = args["pseudonym"] as? String,
            let serviceUuid = args["service_uuid"] as? String
        else {
            result(
                FlutterError(
                    code: "invalid_config", message: "pseudonym and service_uuid are required",
                    details: nil))
            return
        }

        let missing = Self.missingPlatformRequirements()
        if !missing.isEmpty {
            // Refusing loudly beats sensing that quietly stops when the screen locks.
            result(
                FlutterError(
                    code: "missing_platform_requirements",
                    message: missing.joined(separator: "; "), details: missing))
            return
        }

        do {
            try ProximitySensor.shared.start(pseudonym: pseudonym, serviceUuid: serviceUuid)
            result(nil)
        } catch {
            result(
                FlutterError(
                    code: "start_failed", message: String(describing: error), details: nil))
        }
    }

    public func onListen(withArguments _: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
        ProximityEvents.shared.attach { eventSink($0) }
        return nil
    }

    public func onCancel(withArguments _: Any?) -> FlutterError? {
        ProximityEvents.shared.detach()
        return nil
    }

    /// What the host app's Info.plist is missing.
    ///
    /// iOS has no equivalent of Android's manifest merging, so these keys cannot be contributed by
    /// the plugin and must be added to the app target. Checking at runtime is the only way to turn
    /// an omission into something visible: without the background modes the app does not crash, it
    /// simply stops sensing when the screen locks, and the study finds out at analysis time.
    static func missingPlatformRequirements() -> [String] {
        var missing: [String] = []
        let info = Bundle.main.infoDictionary ?? [:]

        if (info["NSBluetoothAlwaysUsageDescription"] as? String)?.isEmpty ?? true {
            missing.append("Info.plist is missing NSBluetoothAlwaysUsageDescription")
        }

        let modes = Set(info["UIBackgroundModes"] as? [String] ?? [])
        for required in ["bluetooth-central", "bluetooth-peripheral"] where !modes.contains(required) {
            missing.append("Info.plist UIBackgroundModes is missing \(required)")
        }

        return missing
    }
}
