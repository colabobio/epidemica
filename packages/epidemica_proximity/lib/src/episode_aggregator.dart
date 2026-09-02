import 'package:epidemica_proximity_platform_interface/epidemica_proximity_platform_interface.dart';

import 'aggregator_config.dart';
import 'contact_episode.dart';
import 'distance_bands.dart';
import 'distance_estimator.dart';
import 'open_episode_store.dart';
import 'pair_key.dart' as pk;

/// Reduces peer sightings into contact episodes.
///
/// Pure and synchronous apart from checkpointing: it has no clock, no radio and no
/// database, and every output is a function of the detections fed in. That is deliberate
/// — the rule for how observation time is credited to distance bands is the most
/// consequential piece of logic in the module, and it needs to be testable exhaustively
/// without hardware.
///
/// The central invariant is that credited time never exceeds elapsed time. A sighting
/// is evidence about one instant; treating a silence as continued proximity would
/// manufacture the sustained-contact signal a transmission study is looking for.
class EpisodeAggregator {
  EpisodeAggregator({
    required this.selfPseudonym,
    this.observerDeviceClass = DeviceClass.unknown,
    AggregatorConfig config = const AggregatorConfig(),
    DistanceEstimator? estimator,
    OpenEpisodeStore? store,
  }) : _config = config,
       _estimator = estimator ?? CoarseDistanceEstimator(),
       _store = store;

  /// This participant's pseudonym, needed only to derive the symmetric `pair_key`.
  final String selfPseudonym;

  final DeviceClass observerDeviceClass;

  final AggregatorConfig _config;
  final DistanceEstimator _estimator;
  final OpenEpisodeStore? _store;

  /// Encounters in progress, keyed by peer. Insertion-ordered, which keeps output order
  /// reproducible before sorting.
  final Map<String, _OpenEpisode> _open = {};

  AggregatorConfig get config => _config;

  DistanceEstimator get estimator => _estimator;

  int get openEpisodeCount => _open.length;

  /// Feed one sighting. Returns any episodes it completed — usually none.
  List<ContactEpisode> add(ProximityDetection detection) {
    final out = <ContactEpisode>[];
    var episode = _open[detection.peer];

    if (episode != null &&
        detection.observedAt.difference(episode.lastSeenAt) > _config.maxGap) {
      _emit(episode, episode.lastSeenAt, truncated: false, into: out);
      _open.remove(detection.peer);
      _estimator.forget(detection.peer);
      episode = null;
    }

    final band = _estimator.estimate(
      detection.peer,
      detection.rssi,
      detection.peerDeviceClass,
    );

    if (episode == null) {
      final fresh = _OpenEpisode(
        peer: detection.peer,
        peerDeviceClass: detection.peerDeviceClass,
        startedAt: detection.observedAt,
        lastSeenAt: detection.observedAt,
        lastBand: band,
      );
      fresh.sampleCount = 1;
      fresh.rssis.add(detection.rssi);
      _open[detection.peer] = fresh;
      return _ordered(out);
    }

    if (detection.observedAt.difference(episode.lastSeenAt) >
        _config.dropoutThreshold) {
      episode.gapCount++;
    }

    episode = _extend(episode, detection.observedAt, out);
    episode.lastBand = band;
    episode.sampleCount++;
    episode.rssis.add(detection.rssi);
    if (detection.peerDeviceClass != DeviceClass.unknown) {
      episode.peerDeviceClass = detection.peerDeviceClass;
    }
    return _ordered(out);
  }

  /// Close encounters that have been silent longer than [AggregatorConfig.maxGap].
  ///
  /// Needed because the end of an encounter is marked by the absence of sightings, which
  /// no detection can announce. The host calls this on a timer.
  List<ContactEpisode> tick(DateTime now) {
    final out = <ContactEpisode>[];
    for (final peer in _open.keys.toList()) {
      final episode = _open[peer]!;
      if (now.difference(episode.lastSeenAt) > _config.maxGap) {
        _emit(episode, episode.lastSeenAt, truncated: false, into: out);
        _open.remove(peer);
        _estimator.forget(peer);
      }
    }
    return _ordered(out);
  }

  /// Close every open encounter, for shutdown or end of study.
  List<ContactEpisode> flush() {
    final out = <ContactEpisode>[];
    for (final episode in _open.values) {
      _emit(episode, episode.lastSeenAt, truncated: false, into: out);
      _estimator.forget(episode.peer);
    }
    _open.clear();
    return _ordered(out);
  }

  /// Credit elapsed time to the band the peer was last seen in, splitting the episode at
  /// every maximum-length boundary crossed on the way.
  _OpenEpisode _extend(
    _OpenEpisode episode,
    DateTime now,
    List<ContactEpisode> into,
  ) {
    if (!now.isAfter(episode.lastSeenAt)) return episode;

    var creditable = _config.sampleCredit;
    var current = episode;

    while (true) {
      final boundary = current.startedAt.add(_config.maxEpisode);
      if (now.isBefore(boundary)) {
        current.credit(
          current.lastBand,
          _shorter(now.difference(current.lastSeenAt), creditable),
        );
        current.lastSeenAt = now;
        return current;
      }

      final credited = _shorter(
        boundary.difference(current.lastSeenAt),
        creditable,
      );
      current.credit(current.lastBand, credited);
      creditable -= credited;
      current.lastSeenAt = boundary;
      _emit(current, boundary, truncated: true, into: into);

      current = current.continuation(boundary);
      _open[current.peer] = current;
    }
  }

  void _emit(
    _OpenEpisode episode,
    DateTime endedAt, {
    required bool truncated,
    required List<ContactEpisode> into,
  }) {
    // A continuation that was opened at a boundary and never saw a sighting is
    // bookkeeping, not an observation.
    if (episode.sampleCount == 0) return;
    if (endedAt.difference(episode.startedAt) < _config.minUploadDuration) return;
    if (episode.sampleCount < _config.minUploadSamples) return;

    into.add(
      ContactEpisode(
        peer: episode.peer,
        pairKey: _config.includePairKey
            ? pk.pairKey(selfPseudonym, episode.peer)
            : null,
        startedAt: episode.startedAt,
        endedAt: endedAt,
        bandSeconds: Map.of(episode.bandSeconds),
        bandEdgesM: List.of(_estimator.bandEdgesM),
        minDistanceM: _config.includeMinDistance
            ? minDistanceFor(episode.bandSeconds)
            : null,
        sampleCount: episode.sampleCount,
        gapCount: episode.gapCount,
        rssi: _config.includeRssi && episode.rssis.isNotEmpty
            ? RssiSummary.of(episode.rssis)
            : null,
        observerDeviceClass: _config.includeDeviceClass
            ? observerDeviceClass
            : null,
        peerDeviceClass: _config.includeDeviceClass
            ? episode.peerDeviceClass
            : null,
        estimator: _estimator.name,
        estimatorVersion: _estimator.version,
        truncated: truncated,
      ),
    );
  }

  List<ContactEpisode> _ordered(List<ContactEpisode> episodes) {
    episodes.sort((a, b) {
      final byStart = a.startedAt.compareTo(b.startedAt);
      return byStart != 0 ? byStart : a.peer.compareTo(b.peer);
    });
    return episodes;
  }

  // --- durability -----------------------------------------------------------

  /// Write in-flight state to the [OpenEpisodeStore], if one was supplied.
  Future<void> checkpoint() async => _store?.save(snapshot());

  /// Reload in-flight state written by a previous process.
  ///
  /// Returns false when there was nothing to restore, or when the snapshot belongs to a
  /// different pseudonym: after rotation the open episodes' pair keys would be wrong, so
  /// discarding them is safer than carrying them forward.
  Future<bool> restore() async {
    final snapshot = await _store?.load();
    if (snapshot == null) return false;
    if (snapshot['self'] != selfPseudonym) return false;
    applySnapshot(snapshot);
    return true;
  }

  Map<String, Object?> snapshot() => {
    'version': 1,
    'self': selfPseudonym,
    'estimator': _estimator.snapshot(),
    'open': [for (final episode in _open.values) episode.snapshot()],
  };

  void applySnapshot(Map<String, Object?> snapshot) {
    _open.clear();
    _estimator.restore(
      (snapshot['estimator'] as Map?)?.cast<String, Object?>() ?? const {},
    );
    for (final entry in (snapshot['open'] as List? ?? const [])) {
      final episode = _OpenEpisode.fromSnapshot(
        (entry as Map).cast<String, Object?>(),
      );
      _open[episode.peer] = episode;
    }
  }
}

Duration _shorter(Duration a, Duration b) => a < b ? a : b;

class _OpenEpisode {
  _OpenEpisode({
    required this.peer,
    required this.peerDeviceClass,
    required this.startedAt,
    required this.lastSeenAt,
    required this.lastBand,
  });

  factory _OpenEpisode.fromSnapshot(Map<String, Object?> json) {
    final episode = _OpenEpisode(
      peer: json['peer']! as String,
      peerDeviceClass: DeviceClass.fromJson(json['peer_device_class']),
      startedAt: DateTime.parse(json['started_at']! as String).toUtc(),
      lastSeenAt: DateTime.parse(json['last_seen_at']! as String).toUtc(),
      lastBand: DistanceBand.values.byName(json['last_band']! as String),
    );
    final bands = (json['band_seconds'] as Map).cast<String, Object?>();
    for (final band in DistanceBand.values) {
      episode.bandSeconds[band] = (bands[band.name] as num?)?.toDouble() ?? 0.0;
    }
    episode.sampleCount = (json['sample_count'] as num).toInt();
    episode.gapCount = (json['gap_count'] as num).toInt();
    episode.rssis.addAll(
      (json['rssis'] as List? ?? const []).map((v) => (v as num).toDouble()),
    );
    return episode;
  }

  final String peer;
  DeviceClass peerDeviceClass;
  final DateTime startedAt;
  DateTime lastSeenAt;
  DistanceBand lastBand;

  final Map<DistanceBand, double> bandSeconds = {
    for (final band in DistanceBand.values) band: 0.0,
  };

  int sampleCount = 0;
  int gapCount = 0;
  final List<double> rssis = [];

  void credit(DistanceBand band, Duration duration) {
    if (duration <= Duration.zero) return;
    bandSeconds[band] =
        bandSeconds[band]! +
        duration.inMicroseconds / Duration.microsecondsPerSecond;
  }

  /// The next slice of an encounter that ran past the maximum episode length. Carries
  /// the peer's last known band forward so the boundary itself credits no time twice.
  _OpenEpisode continuation(DateTime at) => _OpenEpisode(
    peer: peer,
    peerDeviceClass: peerDeviceClass,
    startedAt: at,
    lastSeenAt: at,
    lastBand: lastBand,
  );

  Map<String, Object?> snapshot() => {
    'peer': peer,
    'peer_device_class': peerDeviceClass.toJson(),
    'started_at': startedAt.toIso8601String(),
    'last_seen_at': lastSeenAt.toIso8601String(),
    'last_band': lastBand.name,
    'band_seconds': {
      for (final entry in bandSeconds.entries) entry.key.name: entry.value,
    },
    'sample_count': sampleCount,
    'gap_count': gapCount,
    'rssis': rssis,
  };
}
