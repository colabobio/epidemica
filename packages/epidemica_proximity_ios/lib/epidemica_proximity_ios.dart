import 'package:epidemica_proximity_platform_interface/epidemica_proximity_platform_interface.dart';

/// iOS implementation of [ProximityPlatform].
///
/// The protocol is identical on both platforms, so this only registers the shared method-channel
/// implementation. Everything iOS-specific is in `ios/epidemica_proximity_ios/Sources`.
class EpidemicaProximityIOS extends MethodChannelProximity {
  static void registerWith() {
    ProximityPlatform.instance = EpidemicaProximityIOS();
  }
}
