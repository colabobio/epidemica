import 'package:epidemica_core/epidemica_core.dart';
import 'package:flutter/material.dart';

import 'rules.dart';

/// The state document, in the shape the screen needs.
///
/// A read-only view. Every field here came from the server; nothing is derived, defaulted or
/// guessed, because a plausible-looking default is indistinguishable on screen from a real answer.
class GameState {
  const GameState._({
    required this.hasState,
    required this.points,
    required this.epiState,
    required this.day,
    required this.daysTotal,
    required this.totalCases,
    required this.population,
    required this.protectionSource,
    required this.protectedUntil,
    required this.pendingContacts,
    required this.settlement,
    required this.asOf,
  });

  factory GameState.from(ParticipantState? document) {
    if (document == null) {
      return const GameState._(
        hasState: false,
        points: 0,
        epiState: 'unknown',
        day: 0,
        daysTotal: null,
        totalCases: 0,
        population: 0,
        protectionSource: null,
        protectedUntil: null,
        pendingContacts: 0,
        settlement: null,
        asOf: null,
      );
    }

    final state = document.state;
    final settlement = state['settlement'];
    final until = state['protected_until'];

    return GameState._(
      hasState: true,
      points: state['points'] as int? ?? 0,
      epiState: state['epi_state'] as String? ?? 'unknown',
      day: state['day'] as int? ?? 0,
      daysTotal: state['days_total'] as int?,
      totalCases: state['total_cases'] as int? ?? 0,
      population: state['population'] as int? ?? 0,
      protectionSource: state['protection_source'] as String?,
      protectedUntil: until is String ? DateTime.tryParse(until)?.toUtc() : null,
      pendingContacts: state['pending_contacts'] as int? ?? 0,
      settlement: settlement is Map
          ? Settlement.fromJson(settlement.cast<String, Object?>())
          : null,
      asOf: document.asOf,
    );
  }

  final bool hasState;
  final int points;
  final String epiState;
  final int day;

  /// How many days the game lasts, or null for a study that declares no schedule and has no last
  /// day. Null is a real answer here, not a missing one.
  final int? daysTotal;
  final int totalCases;
  final int population;
  final String? protectionSource;

  /// When chosen protection lapses, or null when none is running.
  ///
  /// An instant rather than a flag so the app can expire it without waiting for a tick, which is
  /// what lets a decision show its effect the moment it is made.
  final DateTime? protectedUntil;

  /// Long-enough contacts recorded since the last day was decided.
  ///
  /// Not a promise of points: whether one pays depends on protection and cooldown, which the
  /// server settles at the end of the day. Shown so that a contact is visible while it is
  /// happening rather than only as an unexplained number the following morning.
  final int pendingContacts;

  final Settlement? settlement;
  final DateTime? asOf;

  /// Whether the participant's *chosen* protection is in force right now.
  ///
  /// Protection from a phone that stopped sensing is deliberately not folded in here: that is a
  /// present-tense fact about the device, which only the device can answer, and reading it from a
  /// settled document would leave a shield on screen long after Bluetooth came back on.
  bool protectedAt(DateTime now) => protectedUntil != null && protectedUntil!.isAfter(now);

  bool get protected => protectedAt(DateTime.now().toUtc());

  /// Whether the last day has been settled.
  ///
  /// Read from the document rather than from the device's clock: the game is over when the server
  /// says the final day has been scored, not when a phone thinks the week is up. A study with no
  /// last day never finishes, and must never be shown a final score.
  bool get finished => hasState && daysTotal != null && day >= daysTotal!;

  /// The whole screen is this colour. One glance has to answer "how am I doing".
  Color get colour => switch (epiState) {
    'susceptible' => const Color(0xFF1B7F3B),
    'infected' => const Color(0xFFA5231F),
    'recovered' => const Color(0xFF1B4F8F),
    'dead' => Colors.black,
    _ => const Color(0xFF37474F),
  };

  String get stateLabel => switch (epiState) {
    'susceptible' => 'Healthy',
    'infected' => 'Infected',
    'recovered' => 'Recovered',
    'dead' => 'Died',
    _ => 'Waiting for your first update',
  };

  String get dayLabel {
    if (!hasState) return 'Not started';
    if (finished) return 'Finished · $daysTotal days';
    // `day` is the last day the twin settled, so the day being lived is the next one. Showing the
    // settled number would tell a player on day four that it was still day three.
    final current = day + 1;
    return daysTotal == null ? 'Day $current' : 'Day $current of $daysTotal';
  }

  /// How old the computation is, said plainly.
  String get freshness {
    if (asOf == null) return '';
    final age = DateTime.now().toUtc().difference(asOf!);
    if (age.inMinutes < 90) return 'updated ${age.inMinutes} min ago';
    if (age.inHours < 48) return 'updated ${age.inHours} h ago';
    return 'updated ${age.inDays} days ago';
  }

  // Every line describes the day named at the top of the card, so nothing here says "today".
  static String describe(SettlementLine line) => switch (line.reason) {
    'healthy' => 'Stayed healthy',
    'infected' => 'Infected — no points',
    'protection' => 'Protection',
    'not_sensing' => 'Your phone was not sensing, so the day was not scored',
    'contacts' => '${line.count} contact${line.count == 1 ? '' : 's'}',
    'carried_over' => '${line.count} contact${line.count == 1 ? '' : 's'} from earlier days',
    _ => line.reason,
  };
}
