import 'dart:convert';
import 'dart:math';

import 'package:epidemica_proximity/epidemica_proximity.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scenarios.dart';

/// Steady sightings of one peer at a fixed cadence and signal strength.
List<ProximityDetection> steady({
  required DateTime from,
  required int throughSeconds,
  required int everySeconds,
  required double rssi,
  String peer = peerPseudonym,
  DeviceClass peerClass = DeviceClass.ios,
}) => [
  for (var t = 0; t <= throughSeconds; t += everySeconds)
    ProximityDetection(
      peer: peer,
      rssi: rssi,
      observedAt: from.add(Duration(seconds: t)),
      peerDeviceClass: peerClass,
    ),
];

EpisodeAggregator makeAggregator({
  AggregatorConfig config = const AggregatorConfig(),
  DistanceEstimator? estimator,
  OpenEpisodeStore? store,
}) => EpisodeAggregator(
  selfPseudonym: selfPseudonym,
  observerDeviceClass: DeviceClass.ios,
  config: config,
  estimator: estimator ?? CoarseDistanceEstimator.unsmoothed(),
  store: store,
);

List<ContactEpisode> feed(
  EpisodeAggregator aggregator,
  List<ProximityDetection> detections, {
  bool flush = true,
}) {
  final episodes = <ContactEpisode>[];
  for (final detection in detections) {
    episodes.addAll(aggregator.add(detection));
  }
  if (flush) episodes.addAll(aggregator.flush());
  return episodes;
}

void main() {
  final t0 = DateTime.utc(2026, 8, 11, 9);

  group('episode length', () {
    test('a 40-minute encounter is split, with every episode but the last truncated', () {
      final episodes = feed(
        makeAggregator(),
        steady(from: t0, throughSeconds: 2400, everySeconds: 30, rssi: -60),
      );

      expect(episodes.length, greaterThanOrEqualTo(3));
      for (final episode in episodes.take(episodes.length - 1)) {
        expect(episode.truncated, isTrue, reason: '$episode should be truncated');
      }
      expect(episodes.last.truncated, isFalse);

      // The pieces tile the encounter exactly: no gaps, no overlap, no lost time.
      expect(episodes.first.startedAt, t0);
      expect(episodes.last.endedAt, t0.add(const Duration(seconds: 2400)));
      for (var i = 1; i < episodes.length; i++) {
        expect(episodes[i].startedAt, episodes[i - 1].endedAt);
      }
      expect(
        episodes.fold<double>(0, (sum, e) => sum + e.observedSeconds),
        2400,
      );
    });

    test('the maximum episode length comes from the study, not the binary', () {
      final detections = steady(
        from: t0,
        throughSeconds: 2400,
        everySeconds: 30,
        rssi: -60,
      );
      final long = feed(makeAggregator(), detections);
      final short = feed(
        makeAggregator(
          config: const AggregatorConfig(maxEpisode: Duration(seconds: 300)),
        ),
        detections,
      );

      expect(long.length, 3);
      expect(short.length, 9);
    });
  });

  group('dropouts', () {
    test('a five-minute dropout is bridged, counted, and costs observation time', () {
      final aggregator = makeAggregator();
      final detections = [
        ...steady(from: t0, throughSeconds: 60, everySeconds: 30, rssi: -60),
        ...steady(
          from: t0.add(const Duration(seconds: 360)),
          throughSeconds: 60,
          everySeconds: 30,
          rssi: -60,
        ),
      ];

      final episodes = feed(aggregator, detections);

      expect(episodes.length, 1, reason: 'the dropout is shorter than max gap');
      final episode = episodes.single;
      expect(episode.gapCount, greaterThanOrEqualTo(1));
      expect(episode.wallDuration, const Duration(seconds: 420));
      expect(episode.observedSeconds, lessThan(420));
    });

    test('a silence longer than the maximum gap ends the encounter', () {
      final detections = [
        ...steady(from: t0, throughSeconds: 60, everySeconds: 30, rssi: -60),
        ...steady(
          from: t0.add(const Duration(seconds: 1200)),
          throughSeconds: 60,
          everySeconds: 30,
          rssi: -60,
        ),
      ];

      final episodes = feed(makeAggregator(), detections);

      expect(episodes.length, 2);
      expect(episodes[0].endedAt, t0.add(const Duration(seconds: 60)));
      expect(episodes[1].startedAt, t0.add(const Duration(seconds: 1200)));
      expect(episodes.every((e) => e.gapCount == 0), isTrue);
    });

    test('tick closes an encounter that simply stopped', () {
      final aggregator = makeAggregator();
      feed(
        aggregator,
        steady(from: t0, throughSeconds: 60, everySeconds: 30, rssi: -60),
        flush: false,
      );

      expect(aggregator.tick(t0.add(const Duration(seconds: 120))), isEmpty);
      final closed = aggregator.tick(t0.add(const Duration(seconds: 900)));

      expect(closed.length, 1);
      expect(aggregator.openEpisodeCount, 0);
    });
  });

  group('credited time', () {
    test('band seconds never exceed the elapsed time', () {
      // The aggregator must not invent observation time it did not have. Randomised
      // rather than hand-picked, because the failure mode is an arithmetic edge case.
      final random = Random(20260902);
      final aggregator = makeAggregator(estimator: CoarseDistanceEstimator());

      var at = t0;
      final episodes = <ContactEpisode>[];
      for (var i = 0; i < 400; i++) {
        at = at.add(Duration(seconds: 1 + random.nextInt(400)));
        episodes.addAll(
          aggregator.add(
            ProximityDetection(
              peer: peerPseudonym,
              rssi: -40 - random.nextDouble() * 60,
              observedAt: at,
              peerDeviceClass: DeviceClass.ios,
            ),
          ),
        );
      }
      episodes.addAll(aggregator.flush());

      expect(episodes, isNotEmpty);
      for (final episode in episodes) {
        expect(
          episode.observedSeconds,
          lessThanOrEqualTo(
            episode.wallDuration.inMicroseconds /
                    Duration.microsecondsPerSecond +
                1e-9,
          ),
          reason: '$episode credits more time than elapsed',
        );
      }
      // Without this the assertion above could pass on equality alone.
      expect(
        episodes.any(
          (e) => e.observedSeconds < e.wallDuration.inSeconds,
        ),
        isTrue,
        reason: 'the stream should contain gaps that cost observation time',
      );
    });

    test('a detection arriving out of order credits no time', () {
      final aggregator = makeAggregator();
      final episodes = feed(aggregator, [
        ProximityDetection(peer: peerPseudonym, rssi: -60, observedAt: t0),
        ProximityDetection(
          peer: peerPseudonym,
          rssi: -60,
          observedAt: t0.add(const Duration(seconds: 60)),
        ),
        ProximityDetection(
          peer: peerPseudonym,
          rssi: -60,
          observedAt: t0.add(const Duration(seconds: 30)),
        ),
      ]);

      final episode = episodes.single;
      expect(episode.observedSeconds, 60);
      expect(episode.endedAt, t0.add(const Duration(seconds: 60)));
      expect(episode.sampleCount, 3);
    });
  });

  test('the same detection stream produces identical episodes', () {
    final detections = steady(
      from: t0,
      throughSeconds: 2400,
      everySeconds: 17,
      rssi: -68,
    );

    String render(List<ContactEpisode> episodes) =>
        jsonEncode([for (final e in episodes) e.toPayload()]);

    expect(
      render(feed(makeAggregator(estimator: CoarseDistanceEstimator()), detections)),
      render(feed(makeAggregator(estimator: CoarseDistanceEstimator()), detections)),
    );
  });

  test('peers are tracked independently', () {
    final aggregator = makeAggregator();
    final episodes = feed(aggregator, [
      ...steady(from: t0, throughSeconds: 60, everySeconds: 30, rssi: -60),
      ...steady(
        from: t0.add(const Duration(seconds: 10)),
        throughSeconds: 60,
        everySeconds: 30,
        rssi: -80,
        peer: 'b7c8d9e0-1234-4f56-8a9b-0c1d2e3f4051',
      ),
    ]);

    expect(episodes.length, 2);
    expect(episodes.map((e) => e.peer).toSet().length, 2);
  });

  group('process death', () {
    test('an interrupted encounter is recovered from the open-episode store', () async {
      final store = InMemoryOpenEpisodeStore();
      final firstHalf = steady(
        from: t0,
        throughSeconds: 300,
        everySeconds: 30,
        rssi: -60,
      );
      final secondHalf = steady(
        from: t0.add(const Duration(seconds: 330)),
        throughSeconds: 270,
        everySeconds: 30,
        rssi: -60,
      );

      final before = makeAggregator(store: store);
      expect(feed(before, firstHalf, flush: false), isEmpty);
      await before.checkpoint();
      expect(store.saveCount, 1);

      // The process dies here; only what was checkpointed survives.
      final after = makeAggregator(store: store);
      expect(await after.restore(), isTrue);
      expect(after.openEpisodeCount, 1);

      final episodes = feed(after, secondHalf);
      expect(episodes.length, 1);
      final episode = episodes.single;
      expect(episode.startedAt, t0);
      expect(episode.endedAt, t0.add(const Duration(seconds: 600)));
      expect(episode.sampleCount, firstHalf.length + secondHalf.length);
      expect(episode.observedSeconds, 600);
    });

    test('without recovery the same restart loses the first half of the encounter', () {
      // The counterexample that gives the test above its meaning: the loss is not
      // random, it falls on the longest encounters.
      final firstHalf = steady(
        from: t0,
        throughSeconds: 300,
        everySeconds: 30,
        rssi: -60,
      );
      final secondHalf = steady(
        from: t0.add(const Duration(seconds: 330)),
        throughSeconds: 270,
        everySeconds: 30,
        rssi: -60,
      );

      feed(makeAggregator(), firstHalf, flush: false);
      final episodes = feed(makeAggregator(), secondHalf);

      expect(episodes.single.startedAt, t0.add(const Duration(seconds: 330)));
      expect(episodes.single.observedSeconds, 270);
    });

    test('a snapshot from a different pseudonym is discarded, not adopted', () async {
      final store = InMemoryOpenEpisodeStore();
      final before = makeAggregator(store: store);
      feed(before, steady(from: t0, throughSeconds: 300, everySeconds: 30, rssi: -60),
          flush: false);
      await before.checkpoint();

      final rotated = EpisodeAggregator(
        selfPseudonym: 'ffffffff-0000-4000-8000-000000000000',
        store: store,
        estimator: CoarseDistanceEstimator.unsmoothed(),
      );

      expect(await rotated.restore(), isFalse);
      expect(rotated.openEpisodeCount, 0);
    });
  });

  group('bundle-driven configuration', () {
    test('reads the on_device and upload blocks', () {
      final config = AggregatorConfig.fromModuleConfig(const {
        'on_device': {
          'max_episode_seconds': 600,
          'max_gap_seconds': 120,
          'sample_credit_seconds': 45,
          'dropout_threshold_seconds': 30,
          'include_rssi': false,
          'include_min_distance': false,
          'include_pair_key': false,
          'include_device_class': false,
        },
        'upload': {'min_duration_seconds': 60, 'min_sample_count': 3},
      });

      expect(config.maxEpisode, const Duration(seconds: 600));
      expect(config.maxGap, const Duration(seconds: 120));
      expect(config.sampleCredit, const Duration(seconds: 45));
      expect(config.dropoutThreshold, const Duration(seconds: 30));
      expect(config.includeRssi, isFalse);
      expect(config.includeMinDistance, isFalse);
      expect(config.includePairKey, isFalse);
      expect(config.includeDeviceClass, isFalse);
      expect(config.minUploadDuration, const Duration(seconds: 60));
      expect(config.minUploadSamples, 3);
    });

    test('an empty bundle leaves every default in place', () {
      const defaults = AggregatorConfig();
      final config = AggregatorConfig.fromModuleConfig(const {});

      expect(config.maxEpisode, defaults.maxEpisode);
      expect(config.includeRssi, defaults.includeRssi);
      expect(config.minUploadSamples, defaults.minUploadSamples);
    });

    test('minimisation settings change the payload without changing the build', () {
      final detections = steady(
        from: t0,
        throughSeconds: 120,
        everySeconds: 30,
        rssi: -60,
      );

      final rich = feed(makeAggregator(), detections).single.toPayload();
      final minimal = feed(
        makeAggregator(
          config: AggregatorConfig.fromModuleConfig(const {
            'on_device': {
              'include_rssi': false,
              'include_min_distance': false,
              'include_pair_key': false,
              'include_device_class': false,
            },
          }),
        ),
        detections,
      ).single.toPayload();

      expect(rich.keys, containsAll(['rssi', 'pair_key', 'min_distance_m']));
      expect(minimal.keys, isNot(contains('rssi')));
      expect(minimal.keys, isNot(contains('pair_key')));
      expect(minimal.keys, isNot(contains('min_distance_m')));
      expect(minimal['band_seconds'], rich['band_seconds']);
    });

    test('upload filters discard episodes below the study thresholds', () {
      final config = AggregatorConfig.fromModuleConfig(const {
        'upload': {'min_duration_seconds': 300, 'min_sample_count': 2},
      });

      final brief = feed(
        makeAggregator(config: config),
        steady(from: t0, throughSeconds: 60, everySeconds: 30, rssi: -60),
      );
      final sustained = feed(
        makeAggregator(config: config),
        steady(from: t0, throughSeconds: 600, everySeconds: 30, rssi: -60),
      );

      expect(brief, isEmpty);
      expect(sustained.length, 1);
    });
  });

  test('pair keys are symmetric, so both halves of an encounter reconcile', () {
    expect(
      pairKey(selfPseudonym, peerPseudonym),
      pairKey(peerPseudonym, selfPseudonym),
    );
    expect(pairKey('a', 'b'), isNot(pairKey('a', 'c')));
    expect(pairKey(selfPseudonym, peerPseudonym), matches(RegExp(r'^[0-9a-f]{64}$')));
  });
}
