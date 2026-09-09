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
    this.anchor = ScheduleAnchor.study,
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

  /// What [offset] is measured from.
  ///
  /// The choice follows from what the instrument is *about*. One about the study — "how is the
  /// outbreak going so far" — belongs to the calendar, and a participant who joined after its
  /// window closed was never owed it: they were not there. One about the person — demographics,
  /// baseline beliefs — belongs to them, and is owed whenever they arrive.
  ///
  /// Anchoring the second kind to the study is the failure this exists to prevent: under rolling
  /// enrolment it silently asks nothing of everyone who joined late.
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

    // Refused rather than defaulted. A misspelling here — `enrolment` for `enrollment` — would
    // otherwise fall back to the study's clock and skip the instrument for every late joiner,
    // which is precisely the bug the anchor exists to fix, reintroduced silently.
    final anchor = ScheduleAnchor.parse(raw['anchor']);
    if (anchor == null) return null;

    return ScheduledInstrument(
      instrumentId: id,
      version: version,
      url: url,
      sha256: digest,
      offset: Duration(seconds: offset.round()),
      // A week by default: long enough that an ordinary participant is never locked out, short
      // enough that an answer still refers to roughly the period it was asked about.
      window: Duration(seconds: (raw['window_seconds'] as num?)?.round() ?? 604800),
      anchor: anchor,
    );
  }
}

/// What a scheduled instrument's offset is measured from.
enum ScheduleAnchor {
  /// The instant the study opens. The default, and right for anything about the study itself.
  study,

  /// The instant this participant joined. Right for anything about the participant.
  enrollment;

  /// Reads a bundle's `anchor`, or null if it says something this build does not understand.
  ///
  /// Absent means [study], because that is what every instrument written before anchors existed
  /// meant. A value that is present but unrecognised is not the same thing and is not guessed at.
  static ScheduleAnchor? parse(Object? raw) => switch (raw) {
    null => ScheduleAnchor.study,
    'study' => ScheduleAnchor.study,
    'enrollment' => ScheduleAnchor.enrollment,
    _ => null,
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
  /// Due means the offset has passed and the window has not closed. Both ends matter: showing one
  /// early asks about a period that has not happened, and showing one for ever turns a scheduled
  /// measurement into an open invitation.
  ///
  /// Each entry is timed from its own anchor, so one bundle can carry both kinds at once.
  List<ScheduledInstrument> dueAt(
    DateTime now,
    DateTime startsAt,
    DateTime? enrolledAt,
    Set<String> completed,
  ) {
    final due = [
      for (final entry in entries)
        if (!completed.contains(entry.key))
          if (entry._anchoredAt(startsAt, enrolledAt) case final from?)
            if (!now.isBefore(entry.dueAt(from)) && now.isBefore(entry.closesAt(from))) entry,
    ];

    return due..sort((a, b) => a.offset.compareTo(b.offset));
  }

  /// Whether any entry is still ahead of [now], answered or not.
  ///
  /// What tells the module it still has work to do. Once nothing remains it is finished, and
  /// reporting otherwise would claim the study was still collecting something.
  bool anythingLeft(DateTime now, DateTime startsAt, DateTime? enrolledAt, Set<String> completed) =>
      entries.any((entry) {
        if (completed.contains(entry.key)) return false;
        final from = entry._anchoredAt(startsAt, enrolledAt);
        return from != null && now.isBefore(entry.closesAt(from));
      });
}

extension on ScheduledInstrument {
  /// The instant this entry's offset is measured from, or null if it cannot be known.
  ///
  /// An enrollment-anchored entry on a device that does not know when it joined is never due.
  /// Guessing would ask the question at a moment nobody chose, and the study would have no way to
  /// tell that answer apart from one asked on time.
  DateTime? _anchoredAt(DateTime startsAt, DateTime? enrolledAt) => switch (anchor) {
    ScheduleAnchor.study => startsAt,
    ScheduleAnchor.enrollment => enrolledAt,
  };
}
