/// The Dart-to-native boundary for the Epidemica proximity module.
///
/// Platform implementations (`epidemica_proximity_android`, `epidemica_proximity_ios`)
/// depend on this package and nothing else from Epidemica, so the scanning code and the
/// aggregation code can be developed and tested independently of one another.
library;

export 'src/device_class.dart';
export 'src/proximity_detection.dart';
export 'src/proximity_platform.dart';
