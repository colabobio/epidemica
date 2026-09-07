import 'dart:async';

import 'package:epidemica_core/epidemica_core.dart';
import 'package:epidemica_proximity/epidemica_proximity.dart';

import 'module_store_episode_store.dart';

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

  /// How often encounters nothing announced the end of are closed, and what is still open written
  /// down. Both on one timer because a sweep is the only moment the in-flight set changes without
  /// a detection to prompt it.
  static const Duration sweepInterval = Duration(minutes: 1);

  EpisodeAggregator? _aggregator;
  OpenEpisodeStore? _episodes;
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

    final episodes = ModuleStoreEpisodeStore(context.store);
    final aggregator = EpisodeAggregator(
      selfPseudonym: context.subject,
      observerDeviceClass: await _platform.observerDeviceClass(),
      config: AggregatorConfig.fromModuleConfig(context.config),
      store: episodes,
    );
    _episodes = episodes;
    _aggregator = aggregator;

    // Before anything can be listening. Restoring replaces the whole in-flight set, so a detection
    // that arrived first would be thrown away by the snapshot that follows it.
    await aggregator.restore();

    // An encounter that ended while the process was dead is closed now rather than a sweep later,
    // and the snapshot is rewritten immediately: a restart that found the old one still on disk
    // would record the same episode a second time.
    await sweep();

    _subscription = _platform.events.listen(_onEvent);
    _tick = Timer.periodic(sweepInterval, (_) => unawaited(sweep()));

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
    final aggregator = _aggregator;
    // Whatever is still open is real observation time; emit it rather than discarding it.
    for (final episode in aggregator?.flush() ?? const <ContactEpisode>[]) {
      _emit(episode);
    }
    // Those episodes are in the outbox now. A snapshot left behind would be restored on the next
    // start and recorded again, which the server cannot deduplicate: it would be a second
    // observation with its own sequence number, not a retry of the first.
    await _episodes?.clear();
    _aggregator = null;
    _episodes = null;
    _subscription = null;
    _tick = null;
  }

  @override
  Future<ModuleStatus> status() async {
    if (_aggregator == null) {
      return const ModuleStatus(ModuleState.stopped);
    }

    final missing = await _platform.missingPlatformRequirements();
    if (missing.isNotEmpty) {
      return ModuleStatus(ModuleState.permissionDenied, detail: missing.first);
    }

    // Checked separately from isRunning, and the order matters: a running sensor with the radio
    // off produces no detections and is indistinguishable from a participant who met nobody.
    if (!await _platform.isRadioEnabled()) {
      return const ModuleStatus(ModuleState.radioOff, detail: 'bluetooth');
    }

    if (!await _platform.isRunning()) {
      return const ModuleStatus(ModuleState.stopped, detail: 'sensor not running');
    }

    return const ModuleStatus(ModuleState.sensing);
  }

  void _onEvent(ProximityEvent event) {
    switch (event) {
      case ProximityDetection():
        final closed = _aggregator?.add(event) ?? const <ContactEpisode>[];
        for (final episode in closed) {
          _emit(episode);
        }
        // An episode that has reached the outbox has to leave the snapshot immediately, not at the
        // next sweep. Restoring one that was already recorded would put a second copy of the same
        // encounter in the record, and reconciliation sums a reporter's episodes before choosing
        // the better-observed side — so the duplicate would inflate that pair's dose rather than
        // being absorbed.
        if (closed.isNotEmpty) unawaited(_checkpoint());
      case ProximityDetectionsDropped(:final count):
        droppedDetections += count;
      case ProximitySensingStarted():
        break;
    }
  }

  Future<void> _checkpoint() async => _aggregator?.checkpoint();

  /// Close encounters that ended without saying so, then write down what is still open.
  ///
  /// Runs on a timer, and is worth calling directly when the host learns the process is about to
  /// be suspended: everything in flight is lost otherwise, and the loss falls on whichever
  /// encounter was longest.
  ///
  /// The order is the point. Anything closed here has reached the outbox before the snapshot is
  /// written, so the snapshot never describes an episode that has also been recorded.
  Future<void> sweep() async {
    final aggregator = _aggregator;
    if (aggregator == null) return;

    final closed = aggregator.tick(DateTime.now().toUtc());
    for (final episode in closed) {
      _emit(episode);
    }

    // Skipped only when there is nothing open and nothing was closed, in which case the last
    // checkpoint already said so.
    if (closed.isNotEmpty || aggregator.openEpisodeCount > 0) {
      await aggregator.checkpoint();
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
