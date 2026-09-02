import 'package:meta/meta.dart';

import 'device_class.dart';

/// Everything a platform implementation can report.
///
/// A sealed union rather than a bare detection stream, because "we lost some detections" is
/// information the study needs, not a log line. Making it a member of the same stream forces every
/// consumer to decide what to do about it.
sealed class ProximityEvent {
  const ProximityEvent();
}

/// One sighting of a peer: the smallest unit the native scanner produces.
///
/// Detections are not uploaded. They are reduced on-device to contact episodes, which is both the
/// epidemiologically meaningful quantity and a large reduction in volume and re-identification
/// risk.
@immutable
final class ProximityDetection extends ProximityEvent {
  ProximityDetection({
    required this.peer,
    required this.rssi,
    required DateTime observedAt,
    this.peerDeviceClass = DeviceClass.unknown,
  }) : observedAt = observedAt.toUtc();

  /// Pseudonym advertised by the peer. Never a device address or PII.
  final String peer;

  /// Received signal strength in dBm. Negative; closer is larger.
  final double rssi;

  /// When the radio made the measurement, stamped natively.
  ///
  /// Not the moment Dart received the event: iOS batches background delivery, and an aggregator
  /// that credits observation time from arrival times would misattribute exactly the long
  /// background encounters the study cares most about.
  final DateTime observedAt;

  final DeviceClass peerDeviceClass;

  Map<String, Object?> toJson() => {
    'peer': peer,
    'rssi': rssi,
    'observed_at_ms': observedAt.millisecondsSinceEpoch,
    'peer_device_class': peerDeviceClass.toJson(),
  };

  static ProximityDetection fromJson(Map<String, Object?> json) => ProximityDetection(
    peer: json['peer']! as String,
    rssi: (json['rssi']! as num).toDouble(),
    observedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['observed_at_ms']! as num).toInt(),
      isUtc: true,
    ),
    peerDeviceClass: DeviceClass.fromJson(json['peer_device_class']),
  );

  @override
  bool operator ==(Object other) =>
      other is ProximityDetection &&
      other.peer == peer &&
      other.rssi == rssi &&
      other.observedAt == observedAt &&
      other.peerDeviceClass == peerDeviceClass;

  @override
  int get hashCode => Object.hash(peer, rssi, observedAt, peerDeviceClass);

  @override
  String toString() =>
      'ProximityDetection($peer, ${rssi}dBm, ${observedAt.toIso8601String()}, '
      '${peerDeviceClass.name})';
}

/// Sensing is running and the native buffer has been drained.
@immutable
final class ProximitySensingStarted extends ProximityEvent {
  const ProximitySensingStarted();
}

/// Detections were discarded because the native buffer filled before Dart attached.
///
/// Reported rather than swallowed. Loss here is not random — it happens when the app has been
/// killed and relaunched in the background, which correlates with long unattended encounters — so a
/// study needs to be able to see it in the record rather than infer it from a quiet afternoon.
@immutable
final class ProximityDetectionsDropped extends ProximityEvent {
  const ProximityDetectionsDropped({required this.count, required this.oldestRetained});

  final int count;

  /// Timestamp of the oldest detection that survived, bounding when the loss occurred.
  final DateTime? oldestRetained;

  @override
  String toString() => 'ProximityDetectionsDropped($count)';
}
