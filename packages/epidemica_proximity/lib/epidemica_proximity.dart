/// The Epidemica proximity module.
///
/// Consumes [ProximityDetection]s from a platform implementation and produces
/// [ContactEpisode]s whose payloads validate against
/// `contracts/observations/proximity/contact_episode/1.0.0.json`.
///
/// The aggregator is a plain object: detections in, episodes out, no I/O and no clock of
/// its own. That is what lets the epidemiologically load-bearing logic — how observation
/// time is credited to distance bands — be tested exhaustively in CI without a radio.
library;

export 'package:epidemica_proximity_platform_interface/epidemica_proximity_platform_interface.dart';

export 'src/aggregator_config.dart';
export 'src/contact_episode.dart';
export 'src/distance_bands.dart';
export 'src/distance_estimator.dart';
export 'src/episode_aggregator.dart';
export 'src/open_episode_store.dart';
export 'src/pair_key.dart';
export 'src/service_uuid.dart';
