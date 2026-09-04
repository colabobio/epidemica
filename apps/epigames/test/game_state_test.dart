import 'package:epidemica_core/epidemica_core.dart';
import 'package:epidemica_epigames/src/game_state.dart';
import 'package:epidemica_epigames/src/rules.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reading the state document onto the screen.
///
/// The app's whole job. Every case here is a way of showing a participant something the server did
/// not say — the failure that matters most, because it is invisible to the server and completely
/// convincing to the person holding the phone.
void main() {
  ParticipantState document(Map<String, Object?> state, {DateTime? asOf}) => ParticipantState(
    stateVersion: '1.0',
    studyId: 'c0badf00-1111-4222-8333-444455556666',
    subject: 'alice-0001',
    stateUri: 'https://schemas.epidemica.info/state/epigame/1.0.0.json',
    revision: 3,
    asOf: asOf ?? DateTime.now().toUtc(),
    state: state,
  );

  const healthy = {
    'day': 3,
    'days_total': 7,
    'epi_state': 'susceptible',
    'points': 12,
    'total_cases': 5,
    'population': 60,
  };

  group('before the first update', () {
    test('nothing is invented', () {
      final game = GameState.from(null);

      // A synthesised "you are healthy" is indistinguishable on screen from a measured one, and a
      // participant would act on it.
      expect(game.hasState, isFalse);
      expect(game.stateLabel, 'Waiting for your first update');
      expect(game.protected, isFalse);
    });
  });

  group('the colour', () {
    test('each state has its own', () {
      Color colourFor(String state) =>
          GameState.from(document({...healthy, 'epi_state': state})).colour;

      final colours = {
        for (final s in ['susceptible', 'infected', 'recovered', 'dead']) s: colourFor(s),
      };

      // The screen is read at arm's length in one glance; two states sharing a colour would be a
      // participant misreading their own situation.
      expect(colours.values.toSet().length, 4);
      expect(colourFor('dead'), Colors.black);
    });

    test('an unrecognised state does not borrow a meaningful colour', () {
      final game = GameState.from(document({...healthy, 'epi_state': 'exposed'}));

      expect(game.colour, isNot(GameState.from(document(healthy)).colour));
      expect(game.stateLabel, 'Waiting for your first update');
    });
  });

  group('protection', () {
    test('a chosen protection that is still running shows as protected', () {
      final until = DateTime.now().toUtc().add(const Duration(hours: 6));
      final game = GameState.from(
        document({
          ...healthy,
          'protection_source': 'chosen',
          'protected_until': until.toIso8601String(),
        }),
      );

      expect(game.protected, isTrue);
      expect(game.protectionForced, isFalse);
    });

    test('a chosen protection that has lapsed does not', () {
      // `protection_source` records why a *settled* day was protected and stays on the document
      // afterwards. Reading it as the current state would leave a shield on screen over a
      // participant who is no longer protected at all.
      final game = GameState.from(
        document({
          ...healthy,
          'protection_source': 'chosen',
          'protected_until': DateTime.now()
              .toUtc()
              .subtract(const Duration(minutes: 1))
              .toIso8601String(),
        }),
      );

      expect(game.protected, isFalse);
    });

    test('protection expires on the phone without waiting for a tick', () {
      final until = DateTime.now().toUtc().add(const Duration(minutes: 30));
      final game = GameState.from(
        document({
          ...healthy,
          'protection_source': 'chosen',
          'protected_until': until.toIso8601String(),
        }),
      );

      expect(game.protectedAt(until.subtract(const Duration(minutes: 1))), isTrue);
      expect(game.protectedAt(until.add(const Duration(minutes: 1))), isFalse);
    });

    test('protection from a phone that stopped sensing cannot be released', () {
      final game = GameState.from(document({...healthy, 'protection_source': 'not_sensing'}));

      // Offering a button that cannot work would be worse than offering none: the participant
      // would believe they had turned something off.
      expect(game.protected, isTrue);
      expect(game.protectionForced, isTrue);
    });

    test('no protection source means unprotected', () {
      expect(GameState.from(document(healthy)).protected, isFalse);
    });
  });

  group('staleness', () {
    test('the age of the computation is stated, not implied', () {
      final game = GameState.from(
        document(healthy, asOf: DateTime.now().toUtc().subtract(const Duration(hours: 20))),
      );

      // The screen is a daily computation. An interface that looks live claims a freshness it
      // does not have.
      expect(game.freshness, contains('20 h ago'));
    });

    test('a fresh computation says so in minutes', () {
      final game = GameState.from(
        document(healthy, asOf: DateTime.now().toUtc().subtract(const Duration(minutes: 5))),
      );

      expect(game.freshness, contains('5 min ago'));
    });
  });

  group('the settlement', () {
    test('is read straight from the document', () {
      final game = GameState.from(
        document({
          ...healthy,
          'settlement': {
            'day': 2,
            'opening': 5,
            'closing': 12,
            'lines': [
              {'reason': 'healthy', 'points': 2},
              {'reason': 'contacts', 'points': 5, 'count': 1},
            ],
          },
        }),
      );

      expect(game.settlement!.opening, 5);
      expect(game.settlement!.closing, 12);
      expect(game.settlement!.lines.length, 2);
    });

    test('a withheld day explains itself rather than showing a gap', () {
      const line = SettlementLine('not_sensing', 0);

      expect(GameState.describe(line), contains('not sensing'));
    });

    test('a late contact is described as such', () {
      expect(
        GameState.describe(const SettlementLine('carried_over', 5, count: 1)),
        contains('late'),
      );
    });

    test('one contact is singular and two are plural', () {
      expect(GameState.describe(const SettlementLine('contacts', 5, count: 1)), '1 contact today');
      expect(
        GameState.describe(const SettlementLine('contacts', 10, count: 2)),
        '2 contacts today',
      );
    });

    test('a late credit says the contacts came from earlier days', () {
      // The two contact lines are scored differently and arrive for different reasons, so a
      // participant reading the card has to be able to tell which is which.
      expect(
        GameState.describe(const SettlementLine('carried_over', 30, count: 6)),
        '6 contacts from earlier days, confirmed late',
      );
    });
  });

  group('contacts not yet scored', () {
    test('a recorded contact is visible before the day is settled', () {
      final game = GameState.from(document({...healthy, 'pending_contacts': 2}));

      expect(game.pendingContacts, 2);
    });

    test('a document that says nothing about them reports none', () {
      // Never inferred from anything the phone can see: the count is the server's reconciliation
      // of both sides, and a locally invented one would disagree with the score that follows.
      expect(GameState.from(document(healthy)).pendingContacts, 0);
      expect(GameState.from(null).pendingContacts, 0);
    });
  });

  group('progress', () {
    test('the day shown is the one being lived, not the one last settled', () {
      // `day` is the last day the twin settled. A player whose day 3 has been scored is living
      // day 4, and labelling the screen with the settled number tells them the game is a day
      // behind where they are.
      expect(GameState.from(document(healthy)).dayLabel, 'Day 4 of 7');
    });

    test('before any tick the game is on its first day', () {
      final game = GameState.from(document({...healthy, 'day': 0, 'points': 0}));

      expect(game.dayLabel, 'Day 1 of 7');
      expect(game.finished, isFalse);
    });

    test('the aggregate is the population, not the enrolment', () {
      final game = GameState.from(document(healthy));

      // `population` includes the simulated participants, which is why the information screen has
      // to disclose them: the number would otherwise be quietly wrong.
      expect(game.population, 60);
      expect(game.totalCases, 5);
    });
  });

  group('the end of the game', () {
    test('a study still running is not finished', () {
      expect(GameState.from(document(healthy)).finished, isFalse);
    });

    test('the last settled day ends the game', () {
      final game = GameState.from(document({...healthy, 'day': 7}));

      expect(game.finished, isTrue);
      expect(game.dayLabel, 'Finished · 7 days');
    });

    test('the end is decided by the server, not the phone\'s clock', () {
      // The document says which day was settled. A device with a wrong clock must not be able to
      // end a participant's game early or keep it open after everyone else has finished.
      final stale = GameState.from(
        document({
          ...healthy,
          'day': 7,
        }, asOf: DateTime.now().toUtc().subtract(const Duration(days: 30))),
      );

      expect(stale.finished, isTrue);
    });

    test('a study with no declared length never reports finished', () {
      // An open-ended study has no last day. Inferring one from the current day would show a
      // player GAME OVER on their first morning, every morning.
      final game = GameState.from(document({...healthy, 'days_total': null}));

      expect(game.finished, isFalse);
      expect(game.dayLabel, 'Day 4');
    });

    test('an open-ended study still shows progress, just without a total', () {
      final game = GameState.from(document({...healthy, 'day': 40, 'days_total': null}));

      expect(game.finished, isFalse);
      expect(game.dayLabel, 'Day 41');
    });

    test('a missing total is treated as open-ended rather than as day zero', () {
      final state = Map<String, Object?>.from(healthy)..remove('days_total');

      expect(GameState.from(document(state)).finished, isFalse);
    });
  });
}
