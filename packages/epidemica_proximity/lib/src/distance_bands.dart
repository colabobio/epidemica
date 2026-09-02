/// Distance bands used to summarise an encounter.
///
/// Time-in-band, not mean distance, is the primary measurement: infectious dose
/// accumulates as duration x f(distance), so two minutes at arm's length plus eight
/// minutes across the room is epidemiologically unlike ten minutes at mid-range, yet
/// both average the same.
enum DistanceBand { immediate, close, medium, far }

/// Upper edges in metres of the first three bands; [DistanceBand.far] is unbounded.
///
/// Recorded inline on every episode so the observation stays self-describing if the
/// banding changes, which is what makes datasets poolable across app versions.
const List<double> kDefaultBandEdgesM = [1.0, 2.0, 5.0];

/// The distance reported for each band, in metres.
///
/// A band is an interval, so any single number is a convention. These are the midpoints
/// used by the Epigames coarse model, retained so estimates remain comparable with the
/// existing corpus.
const Map<DistanceBand, double> kBandDistanceM = {
  DistanceBand.immediate: 0.5,
  DistanceBand.close: 1.5,
  DistanceBand.medium: 3.5,
  DistanceBand.far: 8.0,
};
