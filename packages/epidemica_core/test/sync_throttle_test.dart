import 'package:epidemica_core/src/sync/sync_throttle.dart';
import 'package:flutter_test/flutter_test.dart';

/// A clock the test advances by hand, so rate-limit assertions never depend on a real clock.
class _Clock {
  _Clock(this.now);

  DateTime now;

  DateTime call() => now;
}

void main() {
  group('SyncThrottle', () {
    test('runs the first time', () async {
      final clock = _Clock(DateTime.utc(2026, 9, 5));
      final throttle = SyncThrottle(floor: const Duration(minutes: 5), now: clock.call);
      var ran = 0;

      final result = await throttle.run(() async => ran++);

      expect(result, isTrue);
      expect(ran, 1);
    });

    test('skips a run inside the floor', () async {
      final clock = _Clock(DateTime.utc(2026, 9, 5));
      final throttle = SyncThrottle(floor: const Duration(minutes: 5), now: clock.call);
      var ran = 0;

      await throttle.run(() async => ran++);
      clock.now = clock.now.add(const Duration(minutes: 2));

      final result = await throttle.run(() async => ran++);

      expect(result, isFalse);
      expect(ran, 1);
    });

    test('runs again once the floor has passed', () async {
      final clock = _Clock(DateTime.utc(2026, 9, 5));
      final throttle = SyncThrottle(floor: const Duration(minutes: 5), now: clock.call);
      var ran = 0;

      await throttle.run(() async => ran++);
      clock.now = clock.now.add(const Duration(minutes: 6));

      final result = await throttle.run(() async => ran++);

      expect(result, isTrue);
      expect(ran, 2);
    });

    test('a study floor longer than the platform floor wins', () async {
      final clock = _Clock(DateTime.utc(2026, 9, 5));
      final throttle = SyncThrottle(floor: const Duration(minutes: 5), now: clock.call);
      var ran = 0;

      await throttle.run(() async => ran++, const Duration(minutes: 15));
      clock.now = clock.now.add(const Duration(minutes: 10));

      final result = await throttle.run(() async => ran++, const Duration(minutes: 15));

      expect(result, isFalse);
      expect(ran, 1);
    });

    test('a study floor shorter than the platform floor loses', () async {
      final clock = _Clock(DateTime.utc(2026, 9, 5));
      final throttle = SyncThrottle(floor: const Duration(minutes: 5), now: clock.call);
      var ran = 0;

      await throttle.run(() async => ran++, const Duration(seconds: 60));
      clock.now = clock.now.add(const Duration(minutes: 2));

      final result = await throttle.run(() async => ran++, const Duration(seconds: 60));

      expect(result, isFalse);
      expect(ran, 1);
    });

    test('a failed action still counts as a run for the floor', () async {
      final clock = _Clock(DateTime.utc(2026, 9, 5));
      final throttle = SyncThrottle(floor: const Duration(minutes: 5), now: clock.call);
      var attempts = 0;

      await expectLater(
        throttle.run(() async {
          attempts++;
          throw StateError('network down');
        }),
        throwsStateError,
      );

      clock.now = clock.now.add(const Duration(minutes: 2));
      final result = await throttle.run(() async => attempts++);

      // A failed attempt is still an attempt: the floor exists so a bad network cannot be hammered
      // by retrying as fast as a background trigger can offer.
      expect(result, isFalse);
      expect(attempts, 1);
    });
  });
}
