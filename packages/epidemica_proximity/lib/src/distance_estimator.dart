import 'dart:math' as math;

import 'package:epidemica_proximity_platform_interface/epidemica_proximity_platform_interface.dart';

import 'distance_bands.dart';

/// Turns a stream of RSSI samples for one peer into a distance band.
///
/// Behind an interface because the RSSI-to-distance mapping is the least settled part of
/// proximity sensing: it is hardware-dependent, environment-dependent, and an active
/// research target. Every episode records [name], [version] and [bandEdgesM] so a
/// dataset stays re-derivable after the estimator is replaced.
abstract class DistanceEstimator {
  String get name;

  String get version;

  List<double> get bandEdgesM;

  /// Feed one sample and get the current band for [peer].
  DistanceBand estimate(String peer, double rssi, DeviceClass peerDeviceClass);

  /// Discard smoothing state for [peer], called when an encounter ends so that a later
  /// encounter does not inherit a stale estimate.
  void forget(String peer);

  Map<String, Object?> snapshot();

  void restore(Map<String, Object?> snapshot);
}

/// The Epigames coarse model: a sliding median to reject outliers, then a scalar Kalman
/// filter to damp what remains, then fixed per-hardware RSSI thresholds.
///
/// The thresholds differ by an order of 15 dBm between iOS and Android because the two
/// platforms advertise at different power levels; using one table for both is the
/// commonest way to get proximity badly wrong.
class CoarseDistanceEstimator implements DistanceEstimator {
  CoarseDistanceEstimator({
    this.windowSize = 5,
    this.smoothing = true,
    this.bandEdgesM = kDefaultBandEdgesM,
  }) : assert(windowSize >= 1, 'window must hold at least the current sample');

  /// No median window and no Kalman filter, so one sample maps straight to one band.
  ///
  /// For tests that need a known band at a known instant. Not for production: a single
  /// unfiltered RSSI reading is a poor distance estimate.
  CoarseDistanceEstimator.unsmoothed()
    : this(windowSize: 1, smoothing: false);

  static const String estimatorName = 'coarse_distance';

  /// Version 1 was the Epigames on-device model. This is its Dart port: same thresholds
  /// and same filter constants, but banding moved off the native side so it is testable.
  static const String estimatorVersion = '2.0.0';

  static const Map<DeviceClass, List<double>> _thresholds = {
    // immediate > -55, close > -65, medium > -75
    DeviceClass.ios: [-55, -65, -75],
    DeviceClass.android: [-70, -80, -90],
  };

  /// An unrecognised peer is treated as iOS, which is the conservative choice: the iOS
  /// thresholds are stricter, so an unknown device is placed no closer than it would be
  /// under the Android table.
  static const DeviceClass _fallbackClass = DeviceClass.ios;

  static const double _kalmanMeasurementError = 2.0;
  static const double _kalmanEstimateError = 2.0;
  static const double _kalmanProcessNoise = 0.05;

  final int windowSize;
  final bool smoothing;

  @override
  final List<double> bandEdgesM;

  final Map<String, _PeerFilter> _filters = {};

  @override
  String get name => estimatorName;

  @override
  String get version => estimatorVersion;

  @override
  DistanceBand estimate(String peer, double rssi, DeviceClass peerDeviceClass) {
    final filter = _filters.putIfAbsent(peer, _PeerFilter.new);
    final smoothed = filter.add(
      rssi,
      windowSize: windowSize,
      smoothing: smoothing,
      measurementError: _kalmanMeasurementError,
      estimateError: _kalmanEstimateError,
      processNoise: _kalmanProcessNoise,
    );
    return bandFor(smoothed, peerDeviceClass);
  }

  /// The threshold table applied to an already-smoothed value.
  static DistanceBand bandFor(double rssi, DeviceClass peerDeviceClass) {
    final t = _thresholds[peerDeviceClass] ?? _thresholds[_fallbackClass]!;
    if (rssi > t[0]) return DistanceBand.immediate;
    if (rssi > t[1]) return DistanceBand.close;
    if (rssi > t[2]) return DistanceBand.medium;
    return DistanceBand.far;
  }

  @override
  void forget(String peer) => _filters.remove(peer);

  @override
  Map<String, Object?> snapshot() => {
    'estimator': name,
    'version': version,
    'peers': {
      for (final entry in _filters.entries) entry.key: entry.value.snapshot(),
    },
  };

  @override
  void restore(Map<String, Object?> snapshot) {
    _filters.clear();
    final peers = snapshot['peers'] as Map<String, Object?>? ?? const {};
    for (final entry in peers.entries) {
      _filters[entry.key] = _PeerFilter.fromSnapshot(
        (entry.value! as Map).cast<String, Object?>(),
      );
    }
  }
}

class _PeerFilter {
  _PeerFilter();

  _PeerFilter.fromSnapshot(Map<String, Object?> json)
    : _window = ((json['window'] as List?) ?? const [])
          .map((v) => (v as num).toDouble())
          .toList(),
      _lastEstimate = (json['last_estimate'] as num?)?.toDouble(),
      _estimateError = (json['estimate_error'] as num?)?.toDouble() ?? 2.0;

  List<double> _window = [];
  double? _lastEstimate;
  double _estimateError = 2.0;

  double add(
    double rssi, {
    required int windowSize,
    required bool smoothing,
    required double measurementError,
    required double estimateError,
    required double processNoise,
  }) {
    if (!smoothing) return rssi;

    _window.add(rssi);
    if (_window.length > windowSize) {
      _window.removeRange(0, _window.length - windowSize);
    }
    final median = _median(_window);

    if (_lastEstimate == null) {
      _estimateError = estimateError;
      _lastEstimate = median;
      return median;
    }
    final previous = _lastEstimate!;
    final gain = _estimateError / (_estimateError + measurementError);
    final current = previous + gain * (median - previous);
    _estimateError =
        (1 - gain) * _estimateError + (previous - current).abs() * processNoise;
    _lastEstimate = current;
    return current;
  }

  static double _median(List<double> values) {
    final sorted = List<double>.of(values)..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  Map<String, Object?> snapshot() => {
    'window': _window,
    'last_estimate': _lastEstimate,
    'estimate_error': _estimateError,
  };
}

/// Median, minimum and maximum of the RSSI samples behind an episode.
///
/// Retained only for estimator calibration; omitted entirely in minimal-collection
/// studies, since raw signal strength is a re-identification surface.
class RssiSummary {
  const RssiSummary({
    required this.median,
    required this.min,
    required this.max,
  });

  factory RssiSummary.of(List<double> samples) {
    final sorted = List<double>.of(samples)..sort();
    final mid = sorted.length ~/ 2;
    final median = sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
    return RssiSummary(
      median: median,
      min: sorted.first,
      max: sorted.last,
    );
  }

  final double median;
  final double min;
  final double max;

  Map<String, Object?> toJson() => {
    'median': _compact(median),
    'min': _compact(min),
    'max': _compact(max),
  };

  static num _compact(double v) => v == v.roundToDouble() ? v.round() : v;

  @override
  String toString() => 'RssiSummary(median: $median, min: $min, max: $max)';
}

/// Smallest distance, in metres, among the bands that accrued time.
double? minDistanceFor(Map<DistanceBand, double> bandSeconds) {
  double? best;
  for (final entry in bandSeconds.entries) {
    if (entry.value <= 0) continue;
    final d = kBandDistanceM[entry.key]!;
    best = best == null ? d : math.min(best, d);
  }
  return best;
}
