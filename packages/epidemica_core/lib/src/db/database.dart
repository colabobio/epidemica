import 'package:sqlite3/sqlite3.dart';

import 'schema.dart';

/// Opens the local store.
///
/// Every isolate calls this and gets **its own connection to the same file**. That is the whole
/// multi-isolate strategy: WAL lets one writer and any number of readers work concurrently, and
/// SQLite's own locking serialises the writers. There is no actor, no port, no single owning
/// isolate to keep alive — which matters because the isolate that most needs to write is a
/// background service the OS may start and kill without warning.
///
/// The reference app avoided this problem instead of solving it, keeping its upload queue as a
/// JSON blob in secure storage so only one isolate ever touched a real database. That works until
/// the queue is large, and it costs an O(n) rewrite on every append.
class EpidemicaDatabase {
  EpidemicaDatabase._(this.db);

  final Database db;

  /// How long a writer waits for another isolate's transaction before giving up.
  ///
  /// Without this, a concurrent write fails immediately with SQLITE_BUSY. Five seconds is far
  /// longer than any transaction here should take, so hitting it means something is wrong rather
  /// than merely busy.
  static const Duration busyTimeout = Duration(seconds: 5);

  factory EpidemicaDatabase.open(String path) {
    final db = sqlite3.open(path);
    return EpidemicaDatabase._(db).._configure();
  }

  /// For tests. Shared cache so a second connection in the same process sees the same data.
  factory EpidemicaDatabase.memory() {
    final db = sqlite3.openInMemory();
    return EpidemicaDatabase._(db).._configure();
  }

  void _configure() {
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA busy_timeout = ${busyTimeout.inMilliseconds}');
    // Durability matters more than throughput: an observation acknowledged to a module must
    // survive a power loss, and the write rate here is a handful of rows a minute.
    db.execute('PRAGMA synchronous = FULL');
    db.execute('PRAGMA foreign_keys = ON');
    migrate();
  }

  /// Brings the schema up to [schemaVersion]. Safe to call from any isolate: the whole migration
  /// runs in one transaction, so a second caller either sees the finished schema or waits.
  void migrate() {
    db.execute('BEGIN IMMEDIATE');
    try {
      final current = db.select('PRAGMA user_version').first['user_version'] as int;
      for (var version = current; version < schemaVersion; version++) {
        for (final statement in migrations[version]) {
          db.execute(statement);
        }
      }
      db.execute('PRAGMA user_version = $schemaVersion');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Runs [action] in an immediate transaction, so the write lock is taken up front rather than
  /// on first write. Deferred transactions can fail to upgrade mid-way when another isolate holds
  /// the lock, which is exactly the case this package has to survive.
  T transaction<T>(T Function() action) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      db.execute('COMMIT');
      return result;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  String? readMeta(String key) {
    final rows = db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void writeMeta(String key, String value) {
    db.execute(
      'INSERT INTO meta (key, value) VALUES (?, ?) '
      'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  void close() => db.dispose();
}
