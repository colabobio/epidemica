import 'package:meta/meta.dart';

/// One entry in a study's survey schedule.
///
/// The instrument itself lives elsewhere and versions on its own; this is the study's decision to
/// use a particular version of it at a particular moment.
@immutable
class ScheduledInstrument {
  const ScheduledInstrument({
    required this.instrumentId,
    required this.version,
    required this.url,
    required this.sha256,
    required this.offset,
    required this.window,
    required this.anchor,
  });

  final String instrumentId;
  final String version;

  /// Where the definition is served, and the digest of the exact bytes expected there.
  ///
  /// May be relative, in which case it resolves against the study server: definitions can be
  /// hosted anywhere, and the common case is the server that already serves the bundle.
  ///
  /// Verified like the protocol bundle: a definition that does not match is refused rather than
  /// presented, because questions a study did not author are not the study's questions.
  final Uri url;
  final String sha256;

  /// How long after the study opens this becomes due.
  ///
  /// An offset rather than a day number. Minute-level scheduling makes "day 3" the wrong unit, and
  /// counting days on the device would be a second implementation of something the server already
  /// decides — free to drift, and hardest to notice when it does.
  final Duration offset;

  /// How long it stays answerable. A participant who opens the app late should still be able to
  /// answer rather than find a question that silently expired.
  final Duration window;

  /// What the offset is measured from: the study's start, or this participant's enrollment.
  ///
  /// An instrument about the study belongs to the calendar; one about the participant —
  /// demographics, baseline beliefs — belongs to them, and a late joiner should still be asked.
  final ScheduleAnchor anchor;

  /// A key that changes when the questions change, so a revision is not treated as already done.
  String get key => '$instrumentId@$version';

  DateTime dueAt(DateTime startsAt) => startsAt.add(offset);

  DateTime closesAt(DateTime startsAt) => startsAt.add(offset + window);

  static ScheduledInstrument? parse(Object? raw) {
    if (raw is! Map) return null;

    final id = raw['instrument_id'];
    final version = raw['version'];
    final digest = raw['sha256'];
    final offset = raw['offset_seconds'];
    if (id is! String || version is! String || digest is! String || offset is! num) {
      return null;
    }

    // Defaults to the study server's own route, so the ordinary case needs no URL at all.
    final url = Uri.tryParse((raw['url'] as String?) ?? 'instruments/$id/$version');
    if (url == null) return null;

    return ScheduledInstrument(
      instrumentId: id,
      version: version,
      url: url,
      sha256: digest,
      offset: Duration(seconds: offset.round()),
      // A week by default: long enough that an ordinary participant is never locked out, short
      // enough that an answer still refers to roughly the period it was asked about.
      window: Duration(seconds: (raw['window_seconds'] as num?)?.round() ?? 604800),
      anchor: ScheduleAnchor.parse(raw['anchor'] as String?),
    );
  }
}

/// What an offset is measured from.
enum ScheduleAnchor {
  study,
  enrollment;

  static ScheduleAnchor parse(String? raw) => switch (raw) {
    'enrollment' => ScheduleAnchor.enrollment,
    _ => ScheduleAnchor.study,
  };
}

/// The study's whole survey schedule, and what it says right now.
@immutable
class SurveySchedule {
  const SurveySchedule(this.entries);

  final List<ScheduledInstrument> entries;

  bool get isEmpty => entries.isEmpty;

  /// Reads the `survey` module block from a bundle.
  factory SurveySchedule.fromModuleConfig(Map<String, Object?> config) {
    final raw = config['instruments'];
    if (raw is! List) return const SurveySchedule([]);

    return SurveySchedule([for (final entry in raw) ?ScheduledInstrument.parse(entry)]);
  }

  /// Entries due at [now] and not yet answered, earliest first.
  ///
  /// Due means the offset has passed and the window has not closed. Each entry is timed from its
  /// own anchor: the study's start for one about the study, this participant's enrollment for one
  /// about them. A participant who joins after a study-anchored window closed was never owed that
  /// question; one whose window is measured from joining is owed it regardless of when they came.
  List<ScheduledInstrument> dueAt(
    DateTime now,
    DateTime startsAt,
    DateTime? enrolledAt,
    Set<String> completed,
  ) {
    final due = [
      for (final entry in entries)
        if (!completed.contains(entry.key) && entry._isDue(now, startsAt, enrolledAt)) entry,
    ];

    return due..sort((a, b) => a.offset.compareTo(b.offset));
  }

  /// Whether any entry is still ahead of [now], answered or not.
  ///
  /// What tells the module it still has work to do. Once nothing remains it is finished, and
  /// reporting otherwise would claim the study was still collecting something.
  bool anythingLeft(DateTime now, DateTime startsAt, DateTime? enrolledAt, Set<String> completed) =>
      entries.any(
        (entry) => !completed.contains(entry.key) && entry._isOpen(now, startsAt, enrolledAt),
      );
}

extension on ScheduledInstrument {
  DateTime? _anchor(DateTime startsAt, DateTime? enrolledAt) => switch (anchor) {
    ScheduleAnchor.study => startsAt,
    ScheduleAnchor.enrollment => enrolledAt,
  };

  bool _isDue(DateTime now, DateTime startsAt, DateTime? enrolledAt) {
    final anchor = _anchor(startsAt, enrolledAt);
    if (anchor == null) return false;
    return !now.isBefore(dueAt(anchor)) && now.isBefore(closesAt(anchor));
  }

  bool _isOpen(DateTime now, DateTime startsAt, DateTime? enrolledAt) {
    final anchor = _anchor(startsAt, enrolledAt);
    if (anchor == null) return false;
    return now.isBefore(closesAt(anchor));
  }
}
