import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'scenarios.dart';

/// The contact-episode fixtures are the aggregator's golden file.
///
/// They are generated from real runs rather than written by hand, so they cannot drift
/// into describing a payload the module never emits. The same file is validated against
/// the JSON Schema by the Python and Elixir contract suites, which is what makes
/// "everything this module emits is valid" a checked statement rather than a hope.
///
/// Regenerate with:
///   EPIDEMICA_WRITE_FIXTURES=1 flutter test test/fixture_reproduction_test.dart
void main() {
  final fixtureFile = File(
    '../../contracts/fixtures/observations/proximity/contact_episode/valid.json',
  );

  final generated = [
    for (final scenario in fixtureScenarios)
      {'case': scenario.name, 'instance': scenario.episode().toPayload()},
  ];
  final expected = [...generated, ...handWrittenValidCases];

  if (Platform.environment['EPIDEMICA_WRITE_FIXTURES'] == '1') {
    test('regenerates the contact-episode fixtures', () {
      fixtureFile.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(expected)}\n',
      );
      expect(fixtureFile.existsSync(), isTrue);
    });
    return;
  }

  test('fixture file is present and non-empty', () {
    expect(fixtureFile.existsSync(), isTrue, reason: '${fixtureFile.path} missing');
    expect(expected, isNotEmpty);
  });

  final onDisk =
      (jsonDecode(fixtureFile.readAsStringSync()) as List).cast<Object?>();

  test('every valid fixture is accounted for', () {
    expect(onDisk.length, expected.length);
  });

  for (var i = 0; i < expected.length; i++) {
    final name = (expected[i]['case']! as String);
    test('reproduces fixture: $name', () {
      expect(onDisk[i], expected[i]);
    });
  }
}
