import 'package:epidemica_proximity_platform_interface/epidemica_proximity_platform_interface.dart';
import 'package:meta/meta.dart';

import 'distance_bands.dart';
import 'distance_estimator.dart';

/// A period of sustained proximity to one peer, reduced from raw sightings.
///
/// Carried as the `payload` of an observation envelope. The episode knows nothing about
/// the study, the subject or the sequence number: those belong to the envelope, which
/// `epidemica_core` builds around this payload.
@immutable
class ContactEpisode {
  const ContactEpisode({
    required this.peer,
    required this.startedAt,
    required this.endedAt,
    required this.bandSeconds,
    required this.bandEdgesM,
    required this.sampleCount,
    required this.estimator,
    required this.estimatorVersion,
    this.pairKey,
    this.minDistanceM,
    this.gapCount = 0,
    this.rssi,
    this.observerDeviceClass,
    this.peerDeviceClass,
    this.truncated = false,
  });

  final String peer;
  final String? pairKey;
  final DateTime startedAt;
  final DateTime endedAt;
  final Map<DistanceBand, double> bandSeconds;
  final List<double> bandEdgesM;
  final double? minDistanceM;
  final int sampleCount;
  final int gapCount;
  final RssiSummary? rssi;
  final DeviceClass? observerDeviceClass;
  final DeviceClass? peerDeviceClass;
  final String estimator;
  final String estimatorVersion;
  final bool truncated;

  /// Elapsed time from first to last sighting.
  Duration get wallDuration => endedAt.difference(startedAt);

  /// Seconds actually credited to a distance band.
  ///
  /// Never exceeds [wallDuration]: the difference is time the encounter was known to
  /// continue but no sighting vouched for.
  double get observedSeconds =>
      bandSeconds.values.fold(0.0, (sum, v) => sum + v);

  Map<String, Object?> toPayload() {
    return {
      'peer': peer,
      if (pairKey != null) 'pair_key': pairKey,
      'started_at': _iso(startedAt),
      'ended_at': _iso(endedAt),
      'band_seconds': {
        for (final band in DistanceBand.values)
          band.name: _compact(bandSeconds[band] ?? 0),
      },
      'band_edges_m': bandEdgesM,
      if (minDistanceM != null) 'min_distance_m': minDistanceM,
      'sample_count': sampleCount,
      if (gapCount > 0) 'gap_count': gapCount,
      if (rssi != null) 'rssi': rssi!.toJson(),
      if (observerDeviceClass != null)
        'observer_device_class': observerDeviceClass!.toJson(),
      if (peerDeviceClass != null)
        'peer_device_class': peerDeviceClass!.toJson(),
      'estimator': estimator,
      'estimator_version': estimatorVersion,
      if (truncated) 'truncated': true,
    };
  }

  /// Whole seconds stay integers so payloads compare cleanly against fixtures.
  static num _compact(double v) => v == v.roundToDouble() ? v.round() : v;

  /// UTC with a `Z`, and no `.000` when the instant is on a whole second.
  static String _iso(DateTime dt) {
    final s = dt.toUtc().toIso8601String();
    return s.endsWith('.000Z') ? '${s.substring(0, s.length - 5)}Z' : s;
  }

  @override
  String toString() =>
      'ContactEpisode($peer, ${_iso(startedAt)} -> ${_iso(endedAt)}, '
      'observed ${observedSeconds}s of ${wallDuration.inSeconds}s, '
      'samples $sampleCount, gaps $gapCount'
      '${truncated ? ', truncated' : ''})';
}
