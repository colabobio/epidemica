import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'device_class.dart';
import 'proximity_detection.dart';

/// What a platform implementation must provide.
///
/// Deliberately narrow: scan, stop, and a stream of sightings. Everything
/// epidemiological — smoothing, banding, episode assembly, minimisation — happens in
/// Dart in `epidemica_proximity`, where it runs in CI without a device.
abstract class ProximityPlatform extends PlatformInterface {
  ProximityPlatform() : super(token: _token);

  static final Object _token = Object();

  static ProximityPlatform? _instance;

  static ProximityPlatform get instance {
    final instance = _instance;
    if (instance == null) {
      throw StateError(
        'No ProximityPlatform registered. Add epidemica_proximity_android or '
        'epidemica_proximity_ios to the app, or set a fake in tests.',
      );
    }
    return instance;
  }

  static set instance(ProximityPlatform instance) {
    PlatformInterface.verify(instance, _token);
    _instance = instance;
  }

  /// Sightings of peers, in the order the scanner produced them.
  Stream<ProximityDetection> get detections;

  /// Begin advertising [pseudonym] and scanning for peers.
  Future<void> start({required String pseudonym});

  Future<void> stop();

  /// Hardware class of the device the app is running on.
  Future<DeviceClass> observerDeviceClass();
}
