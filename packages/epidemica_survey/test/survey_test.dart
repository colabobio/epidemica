import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:epidemica_survey/epidemica_survey.dart';
import 'package:flutter_test/flutter_test.dart';

/// What an instrument asks, and when a study wants it answered.
///
/// Scheduling is the whole of the judgement here: everything else is rendering and recording,
/// and both of those live a layer up. What is tested is the cases where asking would be wrong —
/// too early, too late, twice, or from a definition nobody can vouch for.
///
/// Nothing in this file touches `epidemica_core`, which is the point of the package boundary: an
/// instrument can be parsed and scheduled with no outbox, no tokens and no database present.
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

}
