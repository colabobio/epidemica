import 'package:epidemica_proximity_platform_interface/epidemica_proximity_platform_interface.dart';

/// Android implementation of [ProximityPlatform].
///
/// The protocol is identical on both platforms, so this only registers the shared method-channel
/// implementation. Everything Android-specific is in `android/src/main/kotlin`.
class EpidemicaProximityAndroid extends MethodChannelProximity {
  static void registerWith() {
    ProximityPlatform.instance = EpidemicaProximityAndroid();
  }
}
