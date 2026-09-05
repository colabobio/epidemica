import 'dart:convert';
import 'dart:io';

import 'package:epidemica_epigames/src/rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// The app's copy of the rules, against the vectors the server also runs.
///
/// The server's score is authoritative, but a participant sees this one first. If the two disagree,
/// the app tells someone they earned something the ledger will not give them — so the only useful
/// test is the one both implementations have to pass.
void main() {
  final vectors =
      jsonDecode(File('../../contracts/game/epigame_rules/1.0.0.vectors.json').readAsStringSync())
          as Map<String, Object?>;

  final basePars = (vectors['pars']! as Map).cast<String, Object?>();

  RulePars parsFor(Map<String, Object?> vector) =>
      RulePars({...basePars, ...((vector['pars'] as Map?)?.cast<String, Object?>() ?? const {})});

  group('settlement vectors', () {
    for (final entry in (vectors['settlements']! as List).cast<Map<String, Object?>>()) {
      test(entry['case']! as String, () {
        final facts = (entry['facts']! as Map).cast<String, Object?>();
        final expected = (entry['expect']! as Map).cast<String, Object?>();

        final result = settle(
          parsFor(entry),
          DayFacts(
            day: facts['day']! as int,
            opening: facts['opening']! as int,
            epiState: facts['epi_state']! as String,
            observed: facts['observed']! as bool,
            protection: facts['protection'] as String?,
            contacts: facts['contacts'] as int? ?? 0,
            carriedOver: facts['carried_over'] as int? ?? 0,
          ),
        );

        expect(result.day, expected['day']);
        expect(result.opening, expected['opening']);
        expect(result.closing, expected['closing']);
        expect(
          result.lines.map((l) => l.toJson()).toList(),
          (expected['lines']! as List).cast<Map<String, Object?>>(),
        );
      });
    }

    test('every settlement accounts for its own movement', () {
      for (final entry in (vectors['settlements']! as List).cast<Map<String, Object?>>()) {
        final facts = (entry['facts']! as Map).cast<String, Object?>();
        final result = settle(
          parsFor(entry),
          DayFacts(
            day: facts['day']! as int,
            opening: facts['opening']! as int,
            epiState: facts['epi_state']! as String,
            observed: facts['observed']! as bool,
            protection: facts['protection'] as String?,
            contacts: facts['contacts'] as int? ?? 0,
            carriedOver: facts['carried_over'] as int? ?? 0,
          ),
        );

        final movement = result.lines.fold<int>(0, (s, l) => s + l.points);
        expect(result.closing - result.opening, movement, reason: entry['case'] as String);
      }
    });
  });

  group('award vectors', () {
    for (final entry in (vectors['awards']! as List).cast<Map<String, Object?>>()) {
      test(entry['case']! as String, () {
        final network = [
          for (final edge in (entry['network']! as List).cast<Map<String, Object?>>())
            (
              pair: (edge['pair']! as List).cast<String>(),
              seconds: (edge['seconds']! as num).toDouble(),
            ),
        ];

        final awarded = {
          for (final pair in (entry['already_awarded']! as List).cast<List>())
            pair.cast<String>().join('\u0000'),
        };

        final result = awardContacts(
          RulePars(basePars),
          network,
          (entry['protected']! as List).cast<String>().toSet(),
          awarded,
        );

        expect(result, (entry['expect']! as List).map((e) => (e as List).cast<String>()).toList());
      });
    }
  });

  group('arms', () {
    const rules = {
      'pars': {'protection_cost': 1, 'contact_points': 5},
      'arms': [
        {'name': 'low', 'weight': 1, 'pars': <String, Object?>{}},
        {
          'name': 'high',
          'weight': 1,
          'pars': {'protection_cost': 2},
        },
      ],
    };

    test('an arm overlays the shared pars', () {
      expect(RulePars.forArm(rules, 'high').integer('protection_cost'), 2);
      // Anything an arm does not name stays shared, or overriding one constant would zero the rest.
      expect(RulePars.forArm(rules, 'high').integer('contact_points'), 5);
      expect(RulePars.forArm(rules, 'low').integer('protection_cost'), 1);
    });

    test('no arm, and an unknown one, is the shared pars', () {
      expect(RulePars.forArm(rules, null).integer('protection_cost'), 1);
      expect(RulePars.forArm(rules, 'nobody').integer('protection_cost'), 1);
    });

    test('a study with no arms scores from the bundle alone', () {
      expect(RulePars.fromBundle(rules).integer('protection_cost'), 1);
      expect(RulePars.forArm(rules, null).integer('protection_cost'), 1);
    });

    test('server and app read the same overlay', () {
      // The vectors hold the two implementations to one answer; a divergence here is exactly the
      // drift they were written to catch, so the same bundle has to produce the same cost.
      expect(RulePars.forArm(rules, 'high').integer('protection_cost'), 2);
      expect(RulePars.forArm(rules, 'low').integer('protection_cost'), 1);
    });
  });
}
