import 'package:epidemica_proximity/epidemica_proximity.dart';

/// The observing participant in every scenario.
const String selfPseudonym = 'a1b2c3d4-e5f6-4708-9a0b-1c2d3e4f5061';

/// The peer in every scenario.
const String peerPseudonym = 'c9e2f1a0-6b3d-4c88-9a71-2f3e4d5c6b7a';

/// One reproducible run of the aggregator.
///
/// Scenarios use the unsmoothed estimator so that a sample's band is a direct
/// consequence of its RSSI. The median and Kalman stages have their own tests; mixing
/// them in here would make the arithmetic of time-in-band unreadable, which is the one
/// thing these cases exist to pin down.
class Scenario {
  const Scenario({
    required this.name,
    required this.startedAt,
    required this.samples,
    this.config = const AggregatorConfig(),
    this.observerClass = DeviceClass.ios,
    this.peerClass = DeviceClass.unknown,
    this.flushAtEnd = true,
    this.episodeIndex = 0,
  });

  /// Doubles as the fixture's `case` string.
  final String name;

  final DateTime startedAt;

  /// `(offset in seconds from [startedAt], RSSI in dBm)`.
  final List<(int, double)> samples;

  final AggregatorConfig config;
  final DeviceClass observerClass;
  final DeviceClass peerClass;

  /// False when the encounter is meant to still be in progress at the end of the run.
  final bool flushAtEnd;

  /// Which emitted episode this scenario is about.
  final int episodeIndex;

  List<ContactEpisode> run() {
    final aggregator = EpisodeAggregator(
      selfPseudonym: selfPseudonym,
      observerDeviceClass: observerClass,
      config: config,
      estimator: CoarseDistanceEstimator.unsmoothed(),
    );
    final episodes = <ContactEpisode>[];
    for (final (offset, rssi) in samples) {
      episodes.addAll(
        aggregator.add(
          ProximityDetection(
            peer: peerPseudonym,
            rssi: rssi,
            observedAt: startedAt.add(Duration(seconds: offset)),
            peerDeviceClass: peerClass,
          ),
        ),
      );
    }
    if (flushAtEnd) episodes.addAll(aggregator.flush());
    return episodes;
  }

  ContactEpisode episode() => run()[episodeIndex];
}

/// Study bundles differ only in what they ask the module to keep.
const AggregatorConfig _minimalCollection = AggregatorConfig(
  includeRssi: false,
  includeMinDistance: false,
  includePairKey: false,
  includeDeviceClass: false,
);

const AggregatorConfig _noEstimatorDetail = AggregatorConfig(
  includeRssi: false,
  includeMinDistance: false,
  includePairKey: false,
);

/// Scenarios whose payloads are the generated part of the contact-episode fixtures.
final List<Scenario> fixtureScenarios = [
  // Android peer: thresholds are immediate > -70, close > -80, medium > -90.
  // 90 s of silence after the sample at 210 s is a bridged dropout, but it is still
  // within one sample's credit, so no observation time is lost.
  Scenario(
    name: 'typical episode with contact across several distance bands',
    startedAt: DateTime.utc(2026, 8, 11, 14, 3, 22, 481),
    observerClass: DeviceClass.ios,
    peerClass: DeviceClass.android,
    samples: const [
      (0, -60), (15, -61), (30, -62), //                       immediate: 60 s
      (60, -77), (90, -76), (120, -75), //
      (150, -74), (180, -73), (210, -72), //                   close: 150 s + 90 s gap
      (300, -85), (330, -85), (360, -85), (390, -85), (420, -85), // medium: 120 s
    ],
  ),

  Scenario(
    name: 'minimal episode with only the required fields',
    startedAt: DateTime.utc(2026, 8, 11, 14, 3, 22),
    config: _minimalCollection,
    peerClass: DeviceClass.unknown,
    samples: const [(0, -70), (60, -70)],
  ),

  // Continues past the 900 s maximum, so the first episode is cut at the boundary and
  // the sample that crossed it opens the continuation.
  Scenario(
    name: "truncated at the app's maximum episode length",
    startedAt: DateTime.utc(2026, 8, 11, 14),
    observerClass: DeviceClass.ios,
    peerClass: DeviceClass.ios,
    flushAtEnd: false,
    samples: [
      for (var t = 0; t < 300; t += 30) (t, -50.0), //          immediate: 300 s
      for (var t = 300; t <= 900; t += 30) (t, -60.0), //       close: 600 s
    ],
  ),

  Scenario(
    name: 'unknown peer device class, recorded as null rather than guessed',
    startedAt: DateTime.utc(2026, 8, 11, 14, 3, 22),
    config: _noEstimatorDetail,
    observerClass: DeviceClass.ios,
    peerClass: DeviceClass.unknown,
    samples: const [(0, -60), (40, -60), (80, -60), (120, -60)],
  ),

  // A five-minute dropout is bridged, but only 90 s of it can be credited, so the band
  // seconds fall well short of the elapsed time.
  Scenario(
    name: 'dropout long enough that observation time is lost',
    startedAt: DateTime.utc(2026, 8, 11, 9),
    observerClass: DeviceClass.android,
    peerClass: DeviceClass.ios,
    samples: const [
      (0, -60), (30, -60), (60, -60), //
      (360, -60), (390, -60), (420, -60),
    ],
  ),
];

/// Valid payloads the aggregator cannot produce but the schema must keep accepting:
/// a study may send optional estimator detail as an explicit null.
const List<Map<String, Object?>> handWrittenValidCases = [
  {
    'case': 'optional estimator detail sent as explicit null rather than omitted',
    'instance': {
      'peer': peerPseudonym,
      'started_at': '2026-08-11T14:03:22Z',
      'ended_at': '2026-08-11T14:05:22Z',
      'band_seconds': {'immediate': 0, 'close': 120, 'medium': 0, 'far': 0},
      'band_edges_m': [1.0, 2.0, 5.0],
      'min_distance_m': null,
      'sample_count': 4,
      'peer_device_class': null,
      'rssi': null,
      'estimator': 'coarse_distance',
      'estimator_version': '2.0.0',
    },
  },
];
