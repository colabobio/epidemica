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
      jsonDecode(
            File(
              '../../contracts/game/epigame_rules/1.0.0.vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;

  final basePars = (vectors['pars']! as Map).cast<String, Object?>();

  RulePars parsFor(Map<String, Object?> vector) => RulePars({
    ...basePars,
    ...((vector['pars'] as Map?)?.cast<String, Object?>() ?? const {}),
  });

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
      // Anything the arm does not name stays shared, or naming one constant would zero the rest.
      expect(RulePars.forArm(rules, 'high').integer('contact_points'), 5);
      expect(RulePars.forArm(rules, 'low').integer('protection_cost'), 1);
    });

    test('no arm, and an unknown one, is the shared pars', () {
      expect(RulePars.forArm(rules, null).integer('protection_cost'), 1);
      expect(RulePars.forArm(rules, 'nobody').integer('protection_cost'), 1);
    });

    test('a bundle that declares no arms is unaffected', () {
      // Every study written before arms existed has to keep meaning what it meant.
      const plain = {
        'pars': {'protection_cost': 4},
      };

      expect(RulePars.forArm(plain, 'high').integer('protection_cost'), 4);
      expect(RulePars.fromBundle(plain).integer('protection_cost'), 4);
    });

    test('an arm leaves the constants that decide what a contact is alone', () {
      // The bundle schema is what forbids an arm from naming these, so one never reaches a device.
      // What holds here is the consequence: an arm naming only prices leaves every pair-level
      // duration at the study's value, on both sides of the wire.
      expect(RulePars.forArm(rules, 'high').integer('contact_min_seconds'), 600);
      expect(RulePars.forArm(rules, 'high').integer('carry_over_days'), 3);
    });
  });
}
