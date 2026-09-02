import 'package:meta/meta.dart';

import 'device_class.dart';

/// One sighting of a peer: the smallest unit the native scanner produces.
///
/// Detections are not uploaded. They are reduced on-device to contact episodes, which is
/// both the epidemiologically meaningful quantity and a large reduction in volume and
/// re-identification risk.
@immutable
class ProximityDetection {
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

  /// Device clock at the moment of the sighting, in UTC. Skew against real time is
  /// corrected centrally from the envelope's `clock_offset_ms`, not here.
  final DateTime observedAt;

  final DeviceClass peerDeviceClass;

  Map<String, Object?> toJson() => {
    'peer': peer,
    'rssi': rssi,
    'observed_at': observedAt.toIso8601String(),
    'peer_device_class': peerDeviceClass.toJson(),
  };

  static ProximityDetection fromJson(Map<String, Object?> json) => ProximityDetection(
    peer: json['peer']! as String,
    rssi: (json['rssi']! as num).toDouble(),
    observedAt: DateTime.parse(json['observed_at']! as String),
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
