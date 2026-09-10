/// The scoring rules, mirrored from the server.
///
/// The server's copy is authoritative — the cost of protection is what the study measures, and a
/// cost the client can edit is not a cost. This copy exists so a participant sees a contact land
/// immediately rather than a day later, and it is held to
/// `contracts/game/epigame_rules/1.0.0.vectors.json`, the same file the Elixir implementation runs.
/// Without those vectors the two would drift and the number on the screen would stop meaning the
/// number in the ledger.
library;

/// Every constant the rules use, taken from the bundle rather than compiled in.
class RulePars {
  const RulePars(this._values);

  factory RulePars.fromBundle(Map<String, Object?>? rules) => RulePars.forArm(rules, null);

  /// What one participant is paid by: the bundle's constants, overlaid with their arm's.
  ///
  /// The same overlay `Rules.pars_for/2` applies on the server, so the number on the screen and the
  /// number in the ledger stay one answer — which is what the shared vectors exist to hold. An arm
  /// this build does not recognise falls back to the shared constants rather than refusing: the
  /// ledger is authoritative either way, and a participant seeing a stale price is a smaller
  /// failure than one seeing no score at all.
  factory RulePars.forArm(Map<String, Object?>? rules, String? arm) {
    final shared = (rules?['pars'] as Map?)?.cast<String, Object?>() ?? const {};
    return RulePars({...defaults, ...shared, ..._armPars(rules, arm)});
  }

  static Map<String, Object?> _armPars(Map<String, Object?>? rules, String? arm) {
    if (arm == null) return const {};

    for (final entry in (rules?['arms'] as List?) ?? const []) {
      if (entry is Map && entry['name'] == arm) {
        return (entry['pars'] as Map?)?.cast<String, Object?>() ?? const {};
      }
    }

    return const {};
  }

  static const Map<String, Object?> defaults = {
    'healthy_points': 2,
    'infected_points': 0,
    'protection_cost': 1,
    'contact_points': 5,
    'contact_min_seconds': 600,
    'contact_cooldown_days': 1,
    'contact_points_while_infected': false,
    'protection_window_seconds': 86400,
    'carry_over_days': 3,
  };

  final Map<String, Object?> _values;

  int integer(String key) => (_values[key] as num).toInt();
  bool flag(String key) => _values[key] as bool;
}

/// One line of a day's settlement.
class SettlementLine {
  const SettlementLine(this.reason, this.points, {this.count});

  final String reason;
  final int points;
  final int? count;

  Map<String, Object?> toJson() => {
    'reason': reason,
    'points': points,
    if (count != null) 'count': count,
  };

  @override
  bool operator ==(Object other) =>
      other is SettlementLine &&
      other.reason == reason &&
      other.points == points &&
      other.count == count;

  @override
  int get hashCode => Object.hash(reason, points, count);
}

/// A day's arithmetic, in the form a participant can check.
class Settlement {
  const Settlement({
    required this.day,
    required this.opening,
    required this.closing,
    required this.lines,
  });

  factory Settlement.fromJson(Map<String, Object?> json) => Settlement(
    day: json['day']! as int,
    opening: json['opening']! as int,
    closing: json['closing']! as int,
    lines: [
      for (final line in json['lines']! as List)
        SettlementLine(
          (line as Map)['reason'] as String,
          line['points'] as int,
          count: line['count'] as int?,
        ),
    ],
  );

  final int day;
  final int opening;
  final int closing;
  final List<SettlementLine> lines;
}

/// What the participant could have known about their own day.
class DayFacts {
  const DayFacts({
    required this.day,
    required this.opening,
    required this.epiState,
    required this.observed,
    this.protection,
    this.contacts = 0,
    this.carriedOver = 0,
  });

  final int day;
  final int opening;
  final String epiState;
  final bool observed;
  final String? protection;
  final int contacts;
  final int carriedOver;
}

/// Settle one day.
Settlement settle(RulePars pars, DayFacts facts) {
  final lines = _lines(pars, facts);
  final movement = lines.fold<int>(0, (sum, line) => sum + line.points);
  return Settlement(
    day: facts.day,
    opening: facts.opening,
    closing: facts.opening + movement,
    lines: lines,
  );
}

List<SettlementLine> _lines(RulePars pars, DayFacts facts) {
  // A day the study could not observe is neither scored nor charged.
  if (!facts.observed) {
    return const [SettlementLine('not_sensing', 0)];
  }

  final infected = facts.epiState == 'infected';
  final lines = <SettlementLine>[
    infected
        ? SettlementLine('infected', pars.integer('infected_points'))
        : SettlementLine('healthy', pars.integer('healthy_points')),
  ];

  if (facts.protection == 'chosen') {
    lines.add(SettlementLine('protection', -pars.integer('protection_cost')));
  }

  if (infected && !pars.flag('contact_points_while_infected')) {
    return lines;
  }

  final each = pars.integer('contact_points');
  if (facts.contacts > 0) {
    lines.add(SettlementLine('contacts', each * facts.contacts, count: facts.contacts));
  }
  if (facts.carriedOver > 0) {
    lines.add(SettlementLine('carried_over', each * facts.carriedOver, count: facts.carriedOver));
  }
  return lines;
}

/// Which of a day's pairs earn points.
///
/// Takes reconciled pairs, so the app can only ever compute this for the encounters it saw itself:
/// a provisional answer, which is why the screen marks it as such until the server settles.
List<List<String>> awardContacts(
  RulePars pars,
  List<({List<String> pair, double seconds})> network,
  Set<String> protectedSubjects,
  Set<String> alreadyAwarded,
) {
  final minimum = pars.integer('contact_min_seconds');
  return [
    for (final edge in network)
      if (edge.seconds >= minimum &&
          !protectedSubjects.contains(edge.pair[0]) &&
          !protectedSubjects.contains(edge.pair[1]) &&
          !alreadyAwarded.contains(edge.pair.join('\u0000')))
        edge.pair,
  ];
}
