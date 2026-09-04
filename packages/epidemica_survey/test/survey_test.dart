import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:epidemica_core/epidemica_core.dart';
import 'package:epidemica_survey/epidemica_survey.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deciding what to ask, and when.
///
/// The scheduling rules are the whole of the module's judgement: everything else is rendering and
/// recording. What is tested here is the cases where asking would be wrong — too early, too late,
/// twice, or from a definition nobody can vouch for.
void main() {
  final startsAt = DateTime.utc(2026, 9, 4, 6);

  Map<String, Object?> definitionJson({
    String id = 'knowledge',
    String version = '1.0.0',
    List<Map<String, Object?>>? items,
  }) => {
    'instrument_version': '1.0',
    'instrument_id': id,
    'version': version,
    'title': 'What you think about spread',
    'items':
        items ??
        [
          {
            'item_id': 'closest_contact',
            'type': 'single_choice',
            'prompt': 'How close is close?',
            'required': true,
            'options': [
              {'value': 'touching', 'label': 'Touching'},
              {'value': 'arms_length', 'label': "An arm's length"},
            ],
          },
          {
            'item_id': 'confidence',
            'type': 'likert',
            'prompt': 'How confident are you?',
            'scale': {'min': 1, 'max': 5},
          },
        ],
  };

  String digestOf(Map<String, Object?> json) =>
      'sha256:${sha256.convert(utf8.encode(jsonEncode(json)))}';

  Map<String, Object?> entryJson({
    String id = 'knowledge',
    String version = '1.0.0',
    int offset = 900,
    int? window,
    String? digest,
  }) => {
    'instrument_id': id,
    'version': version,
    'url': 'https://example.test/instruments/$id/$version.json',
    'sha256': digest ?? digestOf(definitionJson(id: id, version: version)),
    'offset_seconds': offset,
    if (window != null) 'window_seconds': window,
  };

  group('reading a definition', () {
    test('a complete instrument is read', () {
      final instrument = Instrument.parse(definitionJson())!;

      expect(instrument.id, 'knowledge');
      expect(instrument.version, '1.0.0');
      expect(instrument.items.map((i) => i.id), ['closest_contact', 'confidence']);
      expect(instrument.items.first.required, isTrue);
      expect(instrument.items.last.scale!.values, [1, 2, 3, 4, 5]);
    });

    test('an instrument missing one item is refused entirely', () {
      // Rendering what it can would collect answers to a subset while the response claims the
      // participant saw the whole instrument.
      final broken = definitionJson(
        items: [
          {
            'item_id': 'fine',
            'type': 'single_choice',
            'prompt': 'Fine',
            'options': [
              {'value': 'a', 'label': 'A'},
              {'value': 'b', 'label': 'B'},
            ],
          },
          {'item_id': 'broken', 'type': 'likert', 'prompt': 'No scale'},
        ],
      );

      expect(Instrument.parse(broken), isNull);
    });

    test('a definition written against a newer schema is refused', () {
      final future = {...definitionJson(), 'instrument_version': '2.0'};

      expect(Instrument.parse(future), isNull);
    });

    test('a choice with one option asks nothing and is refused', () {
      final thin = definitionJson(
        items: [
          {
            'item_id': 'pick',
            'type': 'single_choice',
            'prompt': 'Pick',
            'options': [
              {'value': 'a', 'label': 'The only answer'},
            ],
          },
        ],
      );

      expect(Instrument.parse(thin), isNull);
    });
  });

  group('when an instrument is due', () {
    final schedule = SurveySchedule.fromModuleConfig({
      'instruments': [
        entryJson(id: 'first', offset: 900, window: 3600),
        entryJson(id: 'second', offset: 172800),
      ],
    });

    test('nothing is due before its offset has passed', () {
      // Asking early puts a question about a period that has not happened yet.
      expect(schedule.dueAt(startsAt, startsAt, {}), isEmpty);
      expect(schedule.dueAt(startsAt.add(const Duration(minutes: 14)), startsAt, {}), isEmpty);
    });

    test('minute-level offsets are honoured', () {
      final due = schedule.dueAt(startsAt.add(const Duration(minutes: 15)), startsAt, {});

      expect(due.map((e) => e.instrumentId), ['first']);
    });

    test('an offset of days and hours is just a longer offset', () {
      final due = schedule.dueAt(startsAt.add(const Duration(days: 2, hours: 6)), startsAt, {
        'first@1.0.0',
      });

      expect(due.map((e) => e.instrumentId), ['second']);
    });

    test('a closed window is no longer offered', () {
      // Answerable late, but not for ever: a scheduled measurement that never expires becomes an
      // open invitation, and the answer stops referring to the period it asked about.
      final late = startsAt.add(const Duration(minutes: 15) + const Duration(hours: 2));

      expect(schedule.dueAt(late, startsAt, {}).map((e) => e.instrumentId), isEmpty);
    });

    test('one already answered is not offered again', () {
      final now = startsAt.add(const Duration(minutes: 20));

      expect(schedule.dueAt(now, startsAt, {'first@1.0.0'}), isEmpty);
    });

    test('a revised instrument is a different question', () {
      // The key carries the version, so rewording a question asks it again rather than treating
      // the old answer as covering the new wording.
      final revised = SurveySchedule.fromModuleConfig({
        'instruments': [entryJson(id: 'first', version: '1.1.0', offset: 900)],
      });
      final now = startsAt.add(const Duration(minutes: 20));

      expect(revised.dueAt(now, startsAt, {'first@1.0.0'}).map((e) => e.key), ['first@1.1.0']);
    });

    test('the earliest due comes first when several are waiting', () {
      final now = startsAt.add(const Duration(days: 3));

      expect(
        schedule.dueAt(now, startsAt, {}).map((e) => e.instrumentId),
        ['second'],
        reason: 'the first has expired; only the second is still open',
      );
    });

    test('an entry the app cannot understand is dropped, not guessed at', () {
      final schedule = SurveySchedule.fromModuleConfig({
        'instruments': [
          {'instrument_id': 'no_url', 'version': '1.0.0', 'offset_seconds': 60},
          entryJson(id: 'good', offset: 60),
        ],
      });

      expect(schedule.entries.map((e) => e.instrumentId), ['good']);
    });
  });

  group('what the module reports', () {
    late _FakeSource source;
    late _MemoryStore store;

    setUp(() {
      source = _FakeSource({'knowledge@1.0.0': Instrument.parse(definitionJson())!});
      store = _MemoryStore();
    });

    ModuleContext contextFor(
      List<Map<String, Object?>> entries,
      List<Map<String, Object?>> out, {
      DateTime? start,
    }) => ModuleContext(
      config: {'instruments': entries},
      studyStartsAt: start ?? startsAt,
      studyId: 'c0badf00-1111-4222-8333-444455556666',
      subject: 'alice-0001',
      store: store,
      record:
          ({
            required String schemaUri,
            required DateTime observedAt,
            required Map<String, Object?> payload,
          }) {
            out.add({'schema_uri': schemaUri, 'payload': payload});
            return out.length;
          },
    );

    test('it is sensing while anything remains to be asked', () async {
      final module = SurveyModule(
        source: source,
        now: () => startsAt.add(const Duration(minutes: 20)),
      );
      await module.start(contextFor([entryJson()], []));

      expect((await module.status()).isSensing, isTrue);
    });

    test('it has stopped once every window has closed', () async {
      final module = SurveyModule(
        source: source,
        now: () => startsAt.add(const Duration(days: 30)),
      );
      await module.start(contextFor([entryJson(window: 3600)], []));

      // Reporting `sensing` for ever afterwards would claim the study was still collecting
      // something it had finished collecting.
      final status = await module.status();
      expect(status.isSensing, isFalse);
      expect(status.detail, 'every instrument is done');
    });

    test('a study with no schedule has nothing to time anything against', () async {
      final module = SurveyModule(source: source);
      await module.start(
        ModuleContext(
          config: {
            'instruments': [entryJson()],
          },
          studyId: 'c0badf00-1111-4222-8333-444455556666',
          subject: 'alice-0001',
          store: store,
          record:
              ({
                required String schemaUri,
                required DateTime observedAt,
                required Map<String, Object?> payload,
              }) => 1,
        ),
      );

      // Every offset is measured from the study's start. Without one there is nothing to measure
      // against, and guessing would ask a question at a moment nobody chose.
      expect((await module.status()).isSensing, isFalse);
      expect(module.pending, isNull);
    });
  });

  group('answering', () {
    late _FakeSource source;
    late _MemoryStore store;
    late List<Map<String, Object?>> recorded;

    ModuleContext contextFor(List<Map<String, Object?>> entries) => ModuleContext(
      config: {'instruments': entries},
      studyStartsAt: startsAt,
      studyId: 'c0badf00-1111-4222-8333-444455556666',
      subject: 'alice-0001',
      store: store,
      record:
          ({
            required String schemaUri,
            required DateTime observedAt,
            required Map<String, Object?> payload,
          }) {
            recorded.add({'schema_uri': schemaUri, 'payload': payload});
            return recorded.length;
          },
    );

    setUp(() {
      source = _FakeSource({'knowledge@1.0.0': Instrument.parse(definitionJson())!});
      store = _MemoryStore();
      recorded = [];
    });

    Future<SurveyModule> started() async {
      final module = SurveyModule(
        source: source,
        now: () => startsAt.add(const Duration(minutes: 20)),
      );
      await module.start(contextFor([entryJson()]));
      return module;
    }

    test('a due instrument is loaded and offered', () async {
      final module = await started();

      expect(module.pending?.id, 'knowledge');
      expect(module.problem, isNull);
    });

    test('a completed response is recorded as an observation', () async {
      final module = await started();
      final response = module.begin()!;
      response.record('closest_contact', AnswerStatus.answered, value: 'touching');
      response.record('confidence', AnswerStatus.answered, value: 4);

      module.submit(response);

      expect(recorded, hasLength(1));
      final payload = recorded.single['payload']! as Map<String, Object?>;
      expect(payload['instrument_id'], 'knowledge');
      expect(payload['instrument_version'], '1.0.0');
      expect(payload['channel'], 'app');
      expect(payload['partial'], isFalse);
      expect(payload['answers'], hasLength(2));
    });

    test('an unanswered item is reported rather than omitted', () async {
      final module = await started();
      final response = module.begin()!;
      response.record('closest_contact', AnswerStatus.answered, value: 'touching');

      module.submit(response);

      // Attrition within an instrument is a measurement. Sending only what was answered would
      // make a participant who gave up indistinguishable from one who was never asked.
      final answers = (recorded.single['payload']! as Map)['answers']! as List;
      final confidence = answers.firstWhere((a) => (a as Map)['item_id'] == 'confidence') as Map;
      expect(confidence['status'], 'not_reached');
      expect(confidence.containsKey('value'), isFalse);
    });

    test('declining is not the same as never reaching', () async {
      final module = await started();
      final response = module.begin()!;
      response.record('closest_contact', AnswerStatus.refused);
      response.record('confidence', AnswerStatus.answered, value: 2);

      module.submit(response);

      final answers = (recorded.single['payload']! as Map)['answers']! as List;
      final first = answers.first as Map;
      expect(first['status'], 'refused');
      expect(
        (recorded.single['payload']! as Map)['partial'],
        isTrue,
        reason: 'a required item was not answered',
      );
    });

    test('the same instrument is not offered twice', () async {
      final module = await started();
      module.submit(module.begin()!);

      expect(module.pending, isNull);
    });

    test('a restart does not ask again', () async {
      final module = await started();
      module.submit(module.begin()!);

      // The completed set is on the device, not in memory: a process death between the answer and
      // the next launch must not turn one measurement into two.
      final relaunched = SurveyModule(
        source: source,
        now: () => startsAt.add(const Duration(minutes: 25)),
      );
      await relaunched.start(contextFor([entryJson()]));

      expect(relaunched.pending, isNull);
    });

    test('a definition that does not match its digest is never presented', () async {
      final module = SurveyModule(
        source: _RefusingSource(),
        now: () => startsAt.add(const Duration(minutes: 20)),
      );
      await module.start(contextFor([entryJson()]));

      // Questions a study did not author must not reach a participant, and an instrument that
      // cannot be verified today may arrive intact tomorrow, so nothing is marked done either.
      expect(module.pending, isNull);
      expect(module.problem, contains('digest'));
      expect(recorded, isEmpty);
    });
  });
}

class _FakeSource implements InstrumentSource {
  _FakeSource(this.instruments);

  final Map<String, Instrument> instruments;

  @override
  Future<Instrument> fetch(ScheduledInstrument entry) async {
    final instrument = instruments[entry.key];
    if (instrument == null) throw InstrumentUnavailable('no ${entry.key}');
    return instrument;
  }
}

class _RefusingSource implements InstrumentSource {
  @override
  Future<Instrument> fetch(ScheduledInstrument entry) async =>
      throw const InstrumentUnavailable('digest did not match');
}

class _MemoryStore implements ModuleStore {
  final Map<String, String> _values = {};

  @override
  String? read(String key) => _values[key];

  @override
  void write(String key, String value) => _values[key] = value;

  @override
  void delete(String key) => _values.remove(key);
}
