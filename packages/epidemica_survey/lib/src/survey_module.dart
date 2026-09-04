import 'dart:async';
import 'dart:convert';

import 'package:epidemica_core/epidemica_core.dart';
import 'package:flutter/foundation.dart';

import 'instrument.dart';
import 'instrument_source.dart';
import 'response.dart';
import 'schedule.dart';

/// Delivers a study's scheduled instruments.
///
/// The module owns *when* and *whether*; the app owns how the questions look. It records a
/// response as an ordinary observation and keeps no ledger of its own beyond which instruments are
/// finished, which it must remember across restarts or a participant would be asked twice.
class SurveyModule extends ChangeNotifier implements EmbeddedModule {
  SurveyModule({required this.startsAt, InstrumentSource? source, DateTime Function()? now})
    : _source = source ?? HttpInstrumentSource(),
      _now = now ?? (() => DateTime.now().toUtc());

  static const String schemaUri =
      'https://schemas.epidemica.info/observations/instruments/survey_response/1.0.0.json';

  static const String _completedKey = 'completed';

  /// When the study opens. Everything is scheduled as an offset from it, so nothing here counts
  /// days and nothing can disagree with the server about which day it is.
  final DateTime? startsAt;

  final InstrumentSource _source;
  final DateTime Function() _now;

  ModuleContext? _context;
  SurveySchedule _schedule = const SurveySchedule([]);
  Set<String> _completed = {};

  /// The instrument waiting to be answered, once one has been loaded.
  Instrument? get pending => _pending;
  Instrument? _pending;

  ScheduledInstrument? _pendingEntry;

  /// Why the due instrument could not be loaded, if it could not.
  String? get problem => _problem;
  String? _problem;

  @override
  String get id => 'survey';

  @override
  Future<void> start(ModuleContext context) async {
    _context = context;
    _schedule = SurveySchedule.fromModuleConfig(context.config);
    _completed = _readCompleted(context.store);
    await refresh();
  }

  @override
  Future<void> stop() async {
    _context = null;
    _pending = null;
    _pendingEntry = null;
  }

  /// Survey taking is sensing while anything remains to be asked.
  ///
  /// Unlike a sensor there is nothing to keep running, so the honest answer is about the schedule
  /// rather than the hardware: a study still expecting answers is collecting, and one whose last
  /// window has closed has stopped. Reporting `sensing` for ever afterwards would claim the study
  /// was still gathering something it was not.
  @override
  Future<ModuleStatus> status() async {
    if (_context == null) return const ModuleStatus(ModuleState.stopped);
    if (startsAt == null) {
      return const ModuleStatus(ModuleState.stopped, detail: 'study has no schedule');
    }
    if (_schedule.anythingLeft(_now(), startsAt!, _completed)) {
      return const ModuleStatus(ModuleState.sensing);
    }
    return const ModuleStatus(ModuleState.stopped, detail: 'every instrument is done');
  }

  /// Work out what is due and load it. Cheap and safe to call often.
  Future<void> refresh() async {
    final context = _context;
    final start = startsAt;
    if (context == null || start == null) return;

    final due = _schedule.dueAt(_now(), start, _completed);
    if (due.isEmpty) {
      _set(pending: null, entry: null, problem: null);
      return;
    }

    final entry = due.first;
    if (_pendingEntry?.key == entry.key && _pending != null) return;

    try {
      final instrument = await _source.fetch(entry);
      _set(pending: instrument, entry: entry, problem: null);
    } on InstrumentUnavailable catch (e) {
      // Nothing is shown and nothing is marked done: a definition that cannot be verified today
      // may arrive intact on the next attempt, and presenting a partial one would collect answers
      // to questions the study did not write.
      _set(pending: null, entry: null, problem: e.message);
    }
  }

  /// Begin a sitting with the instrument now due.
  SurveyResponse? begin() {
    final instrument = _pending;
    return instrument == null ? null : SurveyResponse(instrument: instrument, startedAt: _now());
  }

  /// Record a response and stop offering the instrument.
  ///
  /// A partial response is uploaded rather than discarded, because abandoning an instrument part
  /// way through is itself a measurement, and one the study cannot recover later.
  void submit(SurveyResponse response) {
    final context = _context;
    final entry = _pendingEntry;
    if (context == null || entry == null) return;

    final completedAt = _now();
    context.record(
      schemaUri: schemaUri,
      observedAt: completedAt,
      payload: response.toPayload(completedAt: completedAt, partial: !response.complete),
    );

    _completed = {..._completed, entry.key};
    context.store.write(_completedKey, jsonEncode(_completed.toList()));
    _set(pending: null, entry: null, problem: null);

    unawaited(refresh());
  }

  void _set({Instrument? pending, ScheduledInstrument? entry, String? problem}) {
    final changed =
        _pending?.id != pending?.id || _pendingEntry?.key != entry?.key || _problem != problem;

    _pending = pending;
    _pendingEntry = entry;
    _problem = problem;

    if (changed) notifyListeners();
  }

  Set<String> _readCompleted(ModuleStore store) {
    final raw = store.read(_completedKey);
    if (raw == null) return {};
    try {
      return {...(jsonDecode(raw) as List).cast<String>()};
    } on Object {
      // A record this build cannot read is treated as nothing done rather than crashing on every
      // launch. Asking again is a nuisance; refusing to start is a broken study.
      return {};
    }
  }
}
