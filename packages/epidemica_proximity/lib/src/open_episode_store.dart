/// Durable storage for encounters that are still open.
///
/// An episode exists only in memory until proximity ends, so a process kill during a
/// long encounter would discard it. That loss would not be random: it falls
/// preferentially on the longest encounters, which is precisely the tail of the
/// contact-duration distribution a transmission study exists to measure. Persisting
/// in-flight state turns a biased loss into no loss.
///
/// The interface is here; the SQLite-backed implementation arrives with
/// `epidemica_core`, which owns the app's database.
abstract class OpenEpisodeStore {
  Future<Map<String, Object?>?> load();

  Future<void> save(Map<String, Object?> snapshot);

  Future<void> clear();
}

/// For tests and for hosts that accept losing in-flight episodes on restart.
class InMemoryOpenEpisodeStore implements OpenEpisodeStore {
  Map<String, Object?>? _snapshot;

  /// Number of times [save] has been called, so tests can assert checkpointing happened.
  int saveCount = 0;

  @override
  Future<Map<String, Object?>?> load() async => _snapshot;

  @override
  Future<void> save(Map<String, Object?> snapshot) async {
    _snapshot = snapshot;
    saveCount++;
  }

  @override
  Future<void> clear() async {
    _snapshot = null;
  }
}
