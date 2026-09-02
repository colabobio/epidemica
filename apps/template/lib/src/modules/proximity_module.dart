import 'dart:async';

import 'package:epidemica_proximity/epidemica_proximity.dart';

import 'embedded_module.dart';

/// Adapts the proximity module to the app's outbox.
///
/// Lives here rather than in `epidemica_proximity` because a sensing package has no business
/// depending on a storage package. The adapter is the app's glue: it owns the aggregator, the
/// subscription, and the tick that closes encounters nothing announces the end of.
class ProximityModule implements EmbeddedModule {
  ProximityModule({this.platform});

  static const String schemaUri =
      'https://schemas.epidemica.info/observations/proximity/contact_episode/1.0.0.json';

  /// Injected in tests; in production the endorsed platform implementation is used.
  final ProximityPlatform? platform;

  EpisodeAggregator? _aggregator;
  StreamSubscription<ProximityEvent>? _subscription;
  Timer? _tick;
  ModuleContext? _context;

  /// Detections lost while Dart was detached. Surfaced to the UI; there is nowhere in the record
  /// to put it until a module-health contract exists.
  int droppedDetections = 0;

  @override
  String get id => 'proximity';

  ProximityPlatform get _platform => platform ?? ProximityPlatform.instance;

  @override
  Future<void> start(ModuleContext context) async {
    if (_aggregator != null) return;
    _context = context;

    final missing = await _platform.missingPlatformRequirements();
    if (missing.isNotEmpty) {
      // Sensing that silently stops when the screen locks is worse than not starting.
      throw StateError('proximity cannot start: ${missing.join('; ')}');
    }

    final aggregator = EpisodeAggregator(
      selfPseudonym: context.subject,
      observerDeviceClass: await _platform.observerDeviceClass(),
      config: AggregatorConfig.fromModuleConfig(context.config),
    );
    _aggregator = aggregator;

    _subscription = _platform.events.listen(_onEvent);
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => _closeIdle());

    await _platform.start(
      ProximityConfig(
        pseudonym: context.subject,
        // Derived from the study, so devices in different studies never discover each other.
        serviceUuid: studyServiceUuid(context.studyId),
      ),
    );
  }

  @override
  Future<void> stop() async {
    await _platform.stop();
    await _subscription?.cancel();
    _tick?.cancel();
    // Whatever is still open is real observation time; emit it rather than discarding it.
    for (final episode in _aggregator?.flush() ?? const <ContactEpisode>[]) {
      _emit(episode);
    }
    _aggregator = null;
    _subscription = null;
    _tick = null;
  }

  void _onEvent(ProximityEvent event) {
    switch (event) {
      case ProximityDetection():
        for (final episode in _aggregator?.add(event) ?? const <ContactEpisode>[]) {
          _emit(episode);
        }
      case ProximityDetectionsDropped(:final count):
        droppedDetections += count;
      case ProximitySensingStarted():
        break;
    }
  }

  void _closeIdle() {
    for (final episode in _aggregator?.tick(DateTime.now().toUtc()) ?? const <ContactEpisode>[]) {
      _emit(episode);
    }
  }

  void _emit(ContactEpisode episode) {
    _context?.record(
      schemaUri: schemaUri,
      observedAt: episode.endedAt,
      payload: episode.toPayload(),
    );
  }
}
