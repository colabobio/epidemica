import 'dart:convert';
import 'dart:io';

import 'package:epidemica_core/epidemica_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Tier 1 study must be unaffected by machinery it never asked for.
///
/// Each of these is a way the platform could quietly start doing something on a study's behalf.
void main() {
  ProtocolBundle parse(Map<String, Object?> json) =>
      ProtocolBundle.parse(utf8.encode(jsonEncode(json)));

  final collectOnly = {
    'bundle_version': '1.0',
    'study_id': 'c0badf00-1111-4222-8333-444455556666',
    'title': 'Contact logging pilot',
    'modules': {
      'proximity': {
        'on_device': {'max_episode_seconds': 900},
      },
    },
  };

  group('a study that only collects', () {
    test('runs no server-side model', () {
      // Absent, not false: a study is never simulated unless it says so.
      expect(parse(collectOnly).twin, isNull);
    });

    test('names only the modules it uses', () {
      expect(parse(collectOnly).requiredModules, ['proximity']);
    });

    test('gets coverage reporting, because that is a data-quality property not a game feature', () {
      expect(parse(collectOnly).healthReportingEnabled, isTrue);
      expect(parse(collectOnly).healthInterval, const Duration(hours: 1));
    });

    test('can switch coverage reporting off and pay nothing for it', () {
      final bundle = parse({
        ...collectOnly,
        'health': {'enabled': false},
      });

      expect(bundle.healthReportingEnabled, isFalse);
    });

    test('can change how precisely a gap is located', () {
      final bundle = parse({
        ...collectOnly,
        'health': {'interval_seconds': 900},
      });

      expect(bundle.healthInterval, const Duration(minutes: 15));
    });
  });

  group('a study that runs a model', () {
    final simulated = {
      ...collectOnly,
      'twin': {
        'engine': 'starsim',
        'state_uri': 'https://schemas.epidemica.info/state/epigame/1.0.0.json',
        'tick_interval_seconds': 86400,
        'population': 50,
        'pars': {
          'diseases': {'type': 'sir', 'beta': 0.05},
        },
      },
    };

    test('declares its engine and the state it will produce', () {
      final twin = parse(simulated).twin!;

      expect(twin['engine'], 'starsim');
      expect(twin['state_uri'], contains('/state/epigame/'));
    });

    test('engine parameters stay opaque to the platform', () {
      // Core knows a model exists and what contract its output obeys. It does not know what a
      // beta is, and must not need to.
      final pars = (parse(simulated).twin!['pars']! as Map).cast<String, Object?>();

      expect(pars['diseases'], {'type': 'sir', 'beta': 0.05});
    });

    test('the same reader handles both kinds of study', () {
      // The Tier 1 bundle and the Tier 2 bundle go through identical code; the difference is one
      // absent block, not a different path.
      expect(parse(collectOnly).studyId, parse(simulated).studyId);
      expect(parse(collectOnly).requiredModules, parse(simulated).requiredModules);
    });
  });

  group('the reference study', () {
    test('contactlog declares no model and no health overrides', () {
      final bundle = ProtocolBundle.parse(
        File('../../studies/contactlog/bundle.json').readAsBytesSync(),
      );

      expect(bundle.twin, isNull, reason: 'contactlog collects; it does not simulate');
      expect(bundle.requiredModules, ['proximity']);
      expect(bundle.healthReportingEnabled, isTrue);
    });
  });
}
