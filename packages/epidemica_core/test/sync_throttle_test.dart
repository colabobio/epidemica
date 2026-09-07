import 'package:epidemica_core/src/sync/sync_throttle.dart';
import 'package:flutter_test/flutter_test.dart';

/// The floor between a platform that offers execution time and an upload that costs battery.
///
/// Every assertion here drives its own clock. A rate limit tested against the real one either
/// sleeps or is flaky, and both are worse than the bug.
void main() {
  late DateTime now;
  DateTime clock() => now;

  SyncThrottle throttle({Duration floor = const Duration(minutes: 5)}) =>
      SyncThrottle(floor: floor, now: clock);

  setUp(() => now = DateTime.utc(2026, 9, 5, 12));

  test('the first offer is always taken', () async {
    var ran = 0;
    expect(await throttle().run(() => ran++), isTrue);
    expect(ran, 1);
  });

  test('an offer inside the floor is declined, and says so', () async {
    final limiter = throttle();
    var ran = 0;

    await limiter.run(() => ran++);
    now = now.add(const Duration(minutes: 2));

    expect(await limiter.run(() => ran++), isFalse);
    expect(ran, 1, reason: 'a declined offer must not run the action');
  });

  test('an offer once the floor has passed is taken', () async {
    final limiter = throttle();
    var ran = 0;

    await limiter.run(() => ran++);
    now = now.add(const Duration(minutes: 6));

    expect(await limiter.run(() => ran++), isTrue);
    expect(ran, 2);
  });

  test('the boundary itself is taken, not declined', () async {
    final limiter = throttle();
    var ran = 0;

    await limiter.run(() => ran++);
    now = now.add(const Duration(minutes: 5));

    expect(await limiter.run(() => ran++), isTrue);
    expect(ran, 2);
  });

  test('a flood of offers produces one run per floor, not one per offer', () async {
    final limiter = throttle();
    var ran = 0;

    // A crowded room on iOS: a wake arrives on every detection.
    for (var minute = 0; minute < 60; minute++) {
      now = now.add(const Duration(minutes: 1));
      await limiter.run(() => ran++);
    }

    expect(ran, 12, reason: 'an hour at a five-minute floor');
  });

  group('a study may slow uploads down but never speed them up', () {
    test('a study floor longer than the platform floor wins', () async {
      final limiter = throttle();
      const study = Duration(minutes: 15);
      var ran = 0;

      await limiter.run(() => ran++, study);
      now = now.add(const Duration(minutes: 10));

      expect(await limiter.run(() => ran++, study), isFalse);
      expect(ran, 1);
    });

    test('a study floor shorter than the platform floor is ignored', () async {
      final limiter = throttle();
      const study = Duration(seconds: 60);
      var ran = 0;

      await limiter.run(() => ran++, study);
      now = now.add(const Duration(minutes: 2));

      expect(await limiter.run(() => ran++, study), isFalse, reason: 'the platform floor stands');
      expect(ran, 1);
    });

    test('a study that declares nothing gets the platform floor alone', () {
      expect(throttle().effectiveFloor(), const Duration(minutes: 5));
      expect(throttle().effectiveFloor(null), const Duration(minutes: 5));
    });
  });

  test('a failed run still spends the interval', () async {
    // Otherwise a device with no connectivity retries as fast as the platform offers, which on a
    // crowded commute is the worst case for the battery and the least likely to succeed.
    final limiter = throttle();
    var attempts = 0;

    await expectLater(
      limiter.run(() async {
        attempts++;
        throw StateError('network down');
      }),
      throwsStateError,
    );

    now = now.add(const Duration(minutes: 2));
    expect(await limiter.run(() => attempts++), isFalse);
    expect(attempts, 1);
  });

  test('nothing is remembered across a restart, so a fresh process may sync at once', () async {
    var ran = 0;
    await throttle().run(() => ran++);

    // A new object stands for a new process. Carrying the instant across would mean a phone
    // relaunched in the background waits before delivering what it recorded before it died.
    expect(await throttle().run(() => ran++), isTrue);
    expect(ran, 2);
  });
}
