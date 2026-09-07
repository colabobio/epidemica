import 'dart:async';

import 'package:epidemica_core/epidemica_core.dart';
import 'package:epidemica_proximity/epidemica_proximity.dart';
import 'package:epidemica_proximity_module/epidemica_proximity_module.dart';
import 'package:flutter_test/flutter_test.dart';

/// The glue between the radio and the outbox.
///
/// What is tested here is what neither package can test alone: that an encounter interrupted by the
/// process dying is recovered rather than lost, and that recovering it never records it twice.
///
/// Times are anchored to the wall clock, because the module sweeps against `DateTime.now()`. A
/// fixture at a fixed date would be closed as idle the moment anything swept, and every test here
/// would pass without exercising the thing it names.
void main() {
  late FakePlatform platform;
  late MemoryStore store;
  late List<Map<String, Object?>> recorded;
  late DateTime now;
  late int syncRequests;

  setUp(() {
    platform = FakePlatform();
    store = MemoryStore();
    recorded = [];
    syncRequests = 0;
    now = DateTime.now().toUtc();
  });

  ModuleContext context({String subject = 'alice-000000001'}) => ModuleContext(
    config: const {
      'on_device': {'max_gap_seconds': 600, 'sample_credit_seconds': 90},
    },
    studyId: '2f1b8c4e-0000-4000-8000-000000000001',
    subject: subject,
    store: store,
    requestSync: () => syncRequests++,
    record:
        ({
          required String schemaUri,
          required DateTime observedAt,
          required Map<String, Object?> payload,
        }) {
          recorded.add(payload);
          return recorded.length;
        },
  );

  DateTime ago(int seconds) => now.subtract(Duration(seconds: seconds));

  ProximityDetection sighting(int secondsAgo) => ProximityDetection(
    peer: 'bob-000000002',
    rssi: -60,
    observedAt: ago(secondsAgo),
    peerDeviceClass: DeviceClass.ios,
  );

  String iso(DateTime at) {
    final s = at.toUtc().toIso8601String();
    return s.endsWith('.000Z') ? '${s.substring(0, s.length - 5)}Z' : s;
  }

  /// Emits sightings and lets the event subscription drain.
  Future<void> observe(List<int> secondsAgo) async {
    for (final seconds in secondsAgo) {
      platform.emit(sighting(seconds));
    }
    await Future<void>.delayed(Duration.zero);
  }

  group('an encounter interrupted by the process dying', () {
    test('is recovered from the store rather than lost', () async {
      final first = ProximityModule(platform: platform);
      await first.start(context());
      await observe([300, 240, 180]);
      await first.sweep();

      // Still open, and therefore never recorded. This is the state that used to be discarded.
      expect(recorded, isEmpty);

      // The process dies here. A new module and a new aggregator, over the same store.
      final second = ProximityModule(platform: FakePlatform());
      await second.start(context());
      await second.stop();

      expect(recorded, hasLength(1));
      final episode = recorded.single;
      expect(episode['peer'], 'bob-000000002');
      expect(episode['started_at'], iso(ago(300)));
      expect(episode['ended_at'], iso(ago(180)));
      expect(episode['sample_count'], 3);

      // 120 s elapsed, all of it vouched for by sightings a minute apart. The recovered episode
      // carries its observation time, not merely its existence.
      final bands = (episode['band_seconds']! as Map).cast<String, Object?>();
      expect(bands.values.fold<num>(0, (sum, v) => sum + (v! as num)), 120);
    });

    test('without a store the same restart loses it', () {
      // The behaviour this wiring exists to prevent, pinned so a regression is visible rather than
      // merely quieter. The loss is not random: it falls on whichever encounter was longest.
      final aggregator = EpisodeAggregator(selfPseudonym: 'alice-000000001')
        ..add(sighting(300))
        ..add(sighting(240));

      final restarted = EpisodeAggregator(selfPseudonym: 'alice-000000001');
      expect(restarted.flush(), isEmpty);
      expect(aggregator.flush(), hasLength(1));
    });

    test('a snapshot from a previous enrolment is discarded, not adopted', () async {
      final first = ProximityModule(platform: platform);
      await first.start(context(subject: 'alice-000000001'));
      await observe([300, 240]);
      await first.sweep();
      expect(recorded, isEmpty);

      // Re-enrolled, so the pseudonym changed. Carrying the encounter forward would attribute it
      // to a participant who was never in it, and its pair key would be wrong.
      final second = ProximityModule(platform: FakePlatform());
      await second.start(context(subject: 'carol-00000003'));
      await second.stop();

      expect(recorded, isEmpty);
    });
  });

  group('a recovered episode is never recorded twice', () {
    test('restarting after a clean stop finds nothing to restore', () async {
      final first = ProximityModule(platform: platform);
      await first.start(context());
      await observe([300, 240]);
      await first.stop();

      expect(recorded, hasLength(1), reason: 'stop flushes what is open');

      final second = ProximityModule(platform: FakePlatform());
      await second.start(context());
      await second.stop();

      expect(recorded, hasLength(1), reason: 'the flushed episode must not come back');
    });

    test('an episode closed by a gap leaves the snapshot at once', () async {
      final first = ProximityModule(platform: platform);
      await first.start(context());

      // The third sighting is past max_gap_seconds, so the first encounter closes and is recorded
      // and a second one opens. No sweep runs in between.
      await observe([1800, 1740, 600]);
      expect(recorded, hasLength(1));

      // The process dies. The closed episode is in the outbox already, so it must not be in the
      // snapshot as well; only the encounter still open may come back.
      final second = ProximityModule(platform: FakePlatform());
      await second.start(context());
      await second.stop();

      expect(recorded, hasLength(2));
      expect(recorded[0]['started_at'], iso(ago(1800)));
      expect(recorded[1]['started_at'], iso(ago(600)));
    });
  });

  group('a background wake', () {
    test('asks the host to sync, without deciding anything itself', () async {
      final module = ProximityModule(platform: platform);
      await module.start(context());

      platform.emit(const ProximityWake());
      await Future<void>.delayed(Duration.zero);

      expect(syncRequests, 1);
    });

    test('is not an observation', () async {
      final module = ProximityModule(platform: platform);
      await module.start(context());

      platform.emit(const ProximityWake());
      await Future<void>.delayed(Duration.zero);

      // A wake says the process is running, not that anything was seen. Recording one would put a
      // fiction in the outbox, and it must not disturb an encounter in progress either.
      expect(recorded, isEmpty);
      expect(store.values, isEmpty);
    });

    test('every offer is passed on: the floor is the host\'s to apply, not the module\'s', () async {
      final module = ProximityModule(platform: platform);
      await module.start(context());

      for (var i = 0; i < 5; i++) {
        platform.emit(const ProximityWake());
      }
      await Future<void>.delayed(Duration.zero);

      // Rate limiting here as well would be a second floor nobody could see from the host, and two
      // limits that disagree are worse than one that is occasionally generous.
      expect(syncRequests, 5);
    });

    test('after stop, a late wake asks for nothing', () async {
      final module = ProximityModule(platform: platform);
      await module.start(context());
      await module.stop();

      platform.emit(const ProximityWake());
      await Future<void>.delayed(Duration.zero);

      expect(syncRequests, 0);
    });
  });

  group('the snapshot', () {    test('is written under one key, so a restart knows where to look', () async {
      final module = ProximityModule(platform: platform);
      await module.start(context());
      await observe([300, 240]);
      await module.sweep();

      expect(store.values.keys, [ModuleStoreEpisodeStore.key]);
    });

    test('is removed on a clean stop, because everything it held has been recorded', () async {
      final module = ProximityModule(platform: platform);
      await module.start(context());
      await observe([300, 240]);
      await module.sweep();
      expect(store.values, isNotEmpty);

      await module.stop();
      expect(store.values, isEmpty);
    });

    test('one this build cannot read costs an encounter, not the module', () async {
      store.values[ModuleStoreEpisodeStore.key] = 'not json';

      final module = ProximityModule(platform: platform);
      await module.start(context());
      expect(recorded, isEmpty);

      // Still collecting: refusing to start would cost every encounter after this one as well.
      await observe([300, 240]);
      await module.stop();
      expect(recorded, hasLength(1));
    });
  });
}

class MemoryStore implements ModuleStore {
  final Map<String, String> values = {};

  @override
  String? read(String key) => values[key];

  @override
  void write(String key, String value) => values[key] = value;

  @override
  void delete(String key) => values.remove(key);
}

class FakePlatform extends ProximityPlatform {
  FakePlatform() : super();

  final _events = StreamController<ProximityEvent>.broadcast();
  bool running = false;

  void emit(ProximityEvent event) => _events.add(event);

  @override
  Stream<ProximityEvent> get events => _events.stream;

  @override
  Future<void> start(ProximityConfig config) async => running = true;

  @override
  Future<void> stop() async => running = false;

  @override
  Future<bool> isRunning() async => running;

  @override
  Future<bool> isRadioEnabled() async => true;

  @override
  Future<DeviceClass> observerDeviceClass() async => DeviceClass.android;

  @override
  Future<List<String>> missingPlatformRequirements() async => const [];
}
