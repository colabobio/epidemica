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
  });

  final String instrumentId;
  final String version;

  /// Where the definition is served, and the digest of the exact bytes expected there.
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

  /// A key that changes when the questions change, so a revision is not treated as already done.
  String get key => '$instrumentId@$version';

  DateTime dueAt(DateTime startsAt) => startsAt.add(offset);

  DateTime closesAt(DateTime startsAt) => startsAt.add(offset + window);

  static ScheduledInstrument? parse(Object? raw) {
    if (raw is! Map) return null;

    final id = raw['instrument_id'];
    final version = raw['version'];
    final url = Uri.tryParse((raw['url'] as String?) ?? '');
    final digest = raw['sha256'];
    final offset = raw['offset_seconds'];
    if (id is! String ||
        version is! String ||
        url == null ||
        !url.hasScheme ||
        digest is! String ||
        offset is! num) {
      return null;
    }

    return ScheduledInstrument(
      instrumentId: id,
      version: version,
      url: url,
      sha256: digest,
      offset: Duration(seconds: offset.round()),
      // A week by default: long enough that an ordinary participant is never locked out, short
      // enough that an answer still refers to roughly the period it was asked about.
      window: Duration(seconds: (raw['window_seconds'] as num?)?.round() ?? 604800),
    );
  }
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
  List<ScheduledInstrument> dueAt(DateTime now, DateTime startsAt, Set<String> completed) {
    final due = [
      for (final entry in entries)
        if (!completed.contains(entry.key) &&
            !now.isBefore(entry.dueAt(startsAt)) &&
            now.isBefore(entry.closesAt(startsAt)))
          entry,
    ];

    return due..sort((a, b) => a.offset.compareTo(b.offset));
  }

  /// Whether any entry is still ahead of [now], answered or not.
  ///
  /// What tells the module it still has work to do. Once nothing remains it is finished, and
  /// reporting otherwise would claim the study was still collecting something.
  bool anythingLeft(DateTime now, DateTime startsAt, Set<String> completed) => entries.any(
    (entry) => !completed.contains(entry.key) && now.isBefore(entry.closesAt(startsAt)),
  );
}
