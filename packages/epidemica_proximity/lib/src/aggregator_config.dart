import 'package:meta/meta.dart';

/// How the aggregator behaves for one study.
///
/// Every value here comes from the study protocol bundle, not from the app binary. That
/// is what makes a Tier 1 study possible: two studies with opposite minimisation rules
/// run on the same signed build, differing only in the bundle they were handed.
@immutable
class AggregatorConfig {
  const AggregatorConfig({
    this.maxEpisode = const Duration(seconds: 900),
    this.maxGap = const Duration(seconds: 600),
    this.sampleCredit = const Duration(seconds: 90),
    this.dropoutThreshold = const Duration(seconds: 75),
    this.includeRssi = true,
    this.includeMinDistance = true,
    this.includePairKey = true,
    this.includeDeviceClass = true,
    this.minUploadDuration = Duration.zero,
    this.minUploadSamples = 1,
  });

  /// Longest episode emitted. Longer encounters are cut here and marked `truncated`, so
  /// that replaying an episode into a simulation timestep needs little apportionment.
  final Duration maxEpisode;

  /// A silence longer than this ends the encounter. A shorter one is bridged, and the
  /// episode continues across it.
  final Duration maxGap;

  /// The most observation time a single sample may vouch for.
  ///
  /// This is the guard against inventing data. A sighting says where the peer was at one
  /// instant; treating a ten-minute silence as ten minutes at that distance would
  /// manufacture exactly the sustained-contact signal a transmission study is looking
  /// for. Time beyond this cap is bridged but credited to no band.
  final Duration sampleCredit;

  /// A silence longer than this counts as a bridged dropout, whether or not observation
  /// time was lost. Recorded as `gap_count`, because an episode assembled across many
  /// dropouts is weaker evidence than a continuously observed one.
  final Duration dropoutThreshold;

  final bool includeRssi;
  final bool includeMinDistance;
  final bool includePairKey;
  final bool includeDeviceClass;

  /// Episodes shorter than this, or with fewer than [minUploadSamples] samples, are
  /// discarded rather than uploaded.
  final Duration minUploadDuration;
  final int minUploadSamples;

  /// Reads the `proximity.on_device` and `proximity.upload` blocks of a protocol bundle.
  /// Absent keys keep their defaults, so a bundle only states what it changes.
  factory AggregatorConfig.fromBundle(Map<String, Object?> bundle) {
    final proximity =
        (bundle['proximity'] as Map?)?.cast<String, Object?>() ?? const {};
    final onDevice =
        (proximity['on_device'] as Map?)?.cast<String, Object?>() ?? const {};
    final upload =
        (proximity['upload'] as Map?)?.cast<String, Object?>() ?? const {};

    const defaults = AggregatorConfig();
    Duration seconds(Map<String, Object?> from, String key, Duration fallback) {
      final value = from[key];
      if (value == null) return fallback;
      return Duration(
        microseconds: ((value as num) * Duration.microsecondsPerSecond).round(),
      );
    }

    bool flag(String key, bool fallback) =>
        onDevice[key] as bool? ?? fallback;

    return AggregatorConfig(
      maxEpisode: seconds(onDevice, 'max_episode_seconds', defaults.maxEpisode),
      maxGap: seconds(onDevice, 'max_gap_seconds', defaults.maxGap),
      sampleCredit: seconds(
        onDevice,
        'sample_credit_seconds',
        defaults.sampleCredit,
      ),
      dropoutThreshold: seconds(
        onDevice,
        'dropout_threshold_seconds',
        defaults.dropoutThreshold,
      ),
      includeRssi: flag('include_rssi', defaults.includeRssi),
      includeMinDistance: flag(
        'include_min_distance',
        defaults.includeMinDistance,
      ),
      includePairKey: flag('include_pair_key', defaults.includePairKey),
      includeDeviceClass: flag(
        'include_device_class',
        defaults.includeDeviceClass,
      ),
      minUploadDuration: seconds(
        upload,
        'min_duration_seconds',
        defaults.minUploadDuration,
      ),
      minUploadSamples:
          (upload['min_sample_count'] as num?)?.toInt() ??
          defaults.minUploadSamples,
    );
  }
}
