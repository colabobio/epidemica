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
        daysTotal: 0,
        totalCases: 0,
        population: 0,
        protectionSource: null,
        settlement: null,
        asOf: null,
      );
    }

    final state = document.state;
    final settlement = state['settlement'];

    return GameState._(
      hasState: true,
      points: state['points'] as int? ?? 0,
      epiState: state['epi_state'] as String? ?? 'unknown',
      day: state['day'] as int? ?? 0,
      daysTotal: state['days_total'] as int? ?? 0,
      totalCases: state['total_cases'] as int? ?? 0,
      population: state['population'] as int? ?? 0,
      protectionSource: state['protection_source'] as String?,
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
  final int daysTotal;
  final int totalCases;
  final int population;
  final String? protectionSource;
  final Settlement? settlement;
  final DateTime? asOf;

  bool get protected => protectionSource != null;

  /// Protection the participant did not choose, and cannot release: their phone stopped sensing.
  bool get protectionForced => protectionSource == 'not_sensing';

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

  String get dayLabel => hasState ? 'Day $day of $daysTotal' : 'Not started';

  /// How old the computation is, said plainly.
  String get freshness {
    if (asOf == null) return '';
    final age = DateTime.now().toUtc().difference(asOf!);
    if (age.inMinutes < 90) return 'updated ${age.inMinutes} min ago';
    if (age.inHours < 48) return 'updated ${age.inHours} h ago';
    return 'updated ${age.inDays} days ago';
  }

  static String describe(SettlementLine line) => switch (line.reason) {
    'healthy' => 'Stayed healthy',
    'infected' => 'Infected — no points today',
    'protection' => 'Protection',
    'not_sensing' => 'Your phone was not sensing, so today was not scored',
    'contacts' => '${line.count} contact${line.count == 1 ? '' : 's'}',
    'carried_over' => '${line.count} contact${line.count == 1 ? '' : 's'} confirmed late',
    _ => line.reason,
  };
}
