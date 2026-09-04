import 'package:meta/meta.dart';

import 'instrument.dart';

/// Why an item has no value.
///
/// These are different missing-data mechanisms and the response contract keeps them apart on
/// purpose: collapsing them into a single null loses the distinction between a participant who
/// passed over a question, one who declined it, and one who never reached it.
enum AnswerStatus {
  answered,
  skipped,
  refused,
  notReached;

  String get wire => switch (this) {
    AnswerStatus.answered => 'answered',
    AnswerStatus.skipped => 'skipped',
    AnswerStatus.refused => 'refused',
    AnswerStatus.notReached => 'not_reached',
  };
}

@immutable
class Answer {
  const Answer({required this.itemId, required this.status, this.value, this.answeredAt});

  final String itemId;
  final AnswerStatus status;
  final Object? value;
  final DateTime? answeredAt;

  Map<String, Object?> toPayload() => {
    'item_id': itemId,
    'status': status.wire,
    if (status == AnswerStatus.answered) 'value': value,
    if (answeredAt != null) 'answered_at': _iso(answeredAt!),
  };
}

/// One sitting with one instrument, as it is being filled in.
class SurveyResponse {
  SurveyResponse({required this.instrument, required DateTime startedAt}) : _startedAt = startedAt;

  final Instrument instrument;
  final DateTime _startedAt;
  final Map<String, Answer> _answers = {};

  Answer? answerFor(String itemId) => _answers[itemId];

  void record(String itemId, AnswerStatus status, {Object? value, DateTime? at}) {
    _answers[itemId] = Answer(
      itemId: itemId,
      status: status,
      value: value,
      answeredAt: at ?? DateTime.now().toUtc(),
    );
  }

  /// Whether every required item has been answered.
  bool get complete => instrument.items
      .where((item) => item.required)
      .every((item) => _answers[item.id]?.status == AnswerStatus.answered);

  /// The payload for `observations/instruments/survey_response`.
  ///
  /// Every item is reported, including ones never reached. An instrument that returned only the
  /// answered items would make attrition within it invisible, and attrition is itself a
  /// measurement.
  Map<String, Object?> toPayload({required DateTime completedAt, required bool partial}) => {
    'instrument_id': instrument.id,
    'instrument_version': instrument.version,
    'channel': 'app',
    'source': 'epidemica',
    'trigger': {'type': 'schedule'},
    'started_at': _iso(_startedAt),
    'completed_at': _iso(completedAt),
    'duration_ms': completedAt.difference(_startedAt).inMilliseconds,
    'partial': partial,
    if (instrument.language != null) 'language': instrument.language,
    'answers': [
      for (final item in instrument.items)
        (_answers[item.id] ?? Answer(itemId: item.id, status: AnswerStatus.notReached)).toPayload(),
    ],
  };
}

String _iso(DateTime dt) {
  final s = dt.toUtc().toIso8601String();
  return s.endsWith('.000Z') ? '${s.substring(0, s.length - 5)}Z' : s;
}
