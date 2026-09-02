import 'package:epidemica_proximity/epidemica_proximity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('threshold table', () {
    test('iOS and Android peers are banded on different scales', () {
      // Roughly 15 dBm apart, because the two platforms advertise at different power.
      // Using one table for both is the commonest way to get proximity badly wrong.
      expect(
        CoarseDistanceEstimator.bandFor(-60, DeviceClass.ios),
        DistanceBand.close,
      );
      expect(
        CoarseDistanceEstimator.bandFor(-60, DeviceClass.android),
        DistanceBand.immediate,
      );
    });

    test('boundaries are exclusive above, matching the reference model', () {
      expect(
        CoarseDistanceEstimator.bandFor(-54.9, DeviceClass.ios),
        DistanceBand.immediate,
      );
      expect(
        CoarseDistanceEstimator.bandFor(-55, DeviceClass.ios),
        DistanceBand.close,
      );
      expect(
        CoarseDistanceEstimator.bandFor(-65, DeviceClass.ios),
        DistanceBand.medium,
      );
      expect(
        CoarseDistanceEstimator.bandFor(-75, DeviceClass.ios),
        DistanceBand.far,
      );
    });

    test('an unrecognised peer is banded no closer than a known one would be', () {
      const rssi = -60.0;
      expect(
        CoarseDistanceEstimator.bandFor(rssi, DeviceClass.unknown).index,
        greaterThanOrEqualTo(
          CoarseDistanceEstimator.bandFor(rssi, DeviceClass.android).index,
        ),
      );
    });
  });

  group('smoothing', () {
    test('a single outlier does not move the band', () {
      final smoothed = CoarseDistanceEstimator();
      final raw = CoarseDistanceEstimator.unsmoothed();

      DistanceBand? last;
      for (final rssi in [-60.0, -60.0, -60.0, -60.0, -100.0]) {
        last = smoothed.estimate('peer', rssi, DeviceClass.ios);
      }

      expect(last, DistanceBand.close);
      expect(raw.estimate('peer', -100, DeviceClass.ios), DistanceBand.far);
    });

    test('state is per peer', () {
      final estimator = CoarseDistanceEstimator();
      for (var i = 0; i < 5; i++) {
        estimator.estimate('a', -50, DeviceClass.ios);
      }
      expect(estimator.estimate('b', -95, DeviceClass.ios), DistanceBand.far);
    });

    test('forget discards smoothing state so a later encounter starts clean', () {
      final estimator = CoarseDistanceEstimator();
      for (var i = 0; i < 5; i++) {
        estimator.estimate('a', -50, DeviceClass.ios);
      }
      final carriedOver = estimator.estimate('a', -95, DeviceClass.ios);

      estimator.forget('a');
      final fresh = estimator.estimate('a', -95, DeviceClass.ios);

      expect(carriedOver, isNot(fresh));
      expect(fresh, DistanceBand.far);
    });

    test('snapshot and restore preserve the filter exactly', () {
      final original = CoarseDistanceEstimator();
      for (final rssi in [-60.0, -62.0, -58.0, -61.0]) {
        original.estimate('a', rssi, DeviceClass.ios);
      }

      final restored = CoarseDistanceEstimator()..restore(original.snapshot());

      expect(
        restored.estimate('a', -59, DeviceClass.ios),
        original.estimate('a', -59, DeviceClass.ios),
      );
      expect(restored.snapshot(), original.snapshot());
    });
  });

  group('summaries', () {
    test('rssi summary orders min below max', () {
      final summary = RssiSummary.of([-85, -60, -75, -70]);
      expect(summary.min, -85);
      expect(summary.max, -60);
      expect(summary.median, -72.5);
      expect(summary.min, lessThan(summary.max));
    });

    test('closest approach comes from the nearest band that accrued time', () {
      expect(
        minDistanceFor({
          DistanceBand.immediate: 0,
          DistanceBand.close: 120,
          DistanceBand.medium: 60,
          DistanceBand.far: 0,
        }),
        kBandDistanceM[DistanceBand.close],
      );
      expect(
        minDistanceFor({for (final b in DistanceBand.values) b: 0.0}),
        isNull,
      );
    });
  });
}
