import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'device_class.dart';
import 'proximity_config.dart';
import 'proximity_event.dart';

/// What a platform implementation must provide.
///
/// Deliberately narrow: start, stop, and a stream of events. Everything epidemiological —
/// smoothing, banding, episode assembly, minimisation — happens in Dart in `epidemica_proximity`,
/// where it runs in CI without a device. Herald types appear only behind this interface, so
/// replacing the radio layer touches two packages and nothing else.
abstract class ProximityPlatform extends PlatformInterface {
  ProximityPlatform() : super(token: _token);

  static final Object _token = Object();

  static ProximityPlatform? _instance;

  static ProximityPlatform get instance {
    final instance = _instance;
    if (instance == null) {
      throw StateError(
        'No ProximityPlatform registered. Add epidemica_proximity to the app, or set a fake '
        'in tests.',
      );
    }
    return instance;
  }

  static set instance(ProximityPlatform instance) {
    PlatformInterface.verify(instance, _token);
    _instance = instance;
  }

  /// Detections and the diagnostics that qualify them, in the order the scanner produced them.
  Stream<ProximityEvent> get events;

  /// Begin advertising and scanning. Idempotent: starting an already-running sensor is a no-op.
  Future<void> start(ProximityConfig config);

  Future<void> stop();

  /// Whether the sensor is currently running, which on iOS may be true before Dart ever called
  /// [start] — the system can relaunch the app for a Bluetooth event.
  Future<bool> isRunning();

  /// Hardware class of the device the app is running on.
  Future<DeviceClass> observerDeviceClass();

  /// Platform requirements the host app has not satisfied, in human-readable form.
  ///
  /// Empty when everything needed is in place. This exists because the expensive failures here are
  /// silent: an iOS app missing a background mode does not crash, it simply stops sensing when the
  /// screen locks, and the study finds out at analysis time.
  Future<List<String>> missingPlatformRequirements();
}
