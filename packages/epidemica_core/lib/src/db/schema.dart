/// The on-device schema.
///
/// Written as literal SQL rather than generated, because the two properties that matter here —
/// how `seq` is allocated and what happens to a row that the server refuses — are transactional
/// facts that ought to be readable in one place.
library;

/// Bumped whenever [migrations] gains an entry.
const int schemaVersion = 1;

/// Applied in order; index `i` migrates from version `i` to `i + 1`.
const List<List<String>> migrations = [_v1];

const List<String> _v1 = [
  // `seq` is INTEGER PRIMARY KEY AUTOINCREMENT rather than a plain rowid, and the distinction is
  // load-bearing. Delivered rows are deleted, and a plain rowid reuses values after deletion — so
  // a drained outbox would start reissuing sequence numbers the server has already recorded under
  // (device_id, seq). The server would dedup them as duplicates and silently discard real
  // observations. AUTOINCREMENT is what makes the counter monotonic for the life of the install.
  '''
  CREATE TABLE outbox (
    seq             INTEGER PRIMARY KEY AUTOINCREMENT,
    study_id        TEXT    NOT NULL,
    protocol_hash   TEXT    NOT NULL,
    subject         TEXT    NOT NULL,
    device_id       TEXT    NOT NULL,
    module          TEXT    NOT NULL,
    schema_uri      TEXT    NOT NULL,
    observed_at     TEXT    NOT NULL,
    clock_offset_ms INTEGER,
    payload         TEXT    NOT NULL,
    created_at      TEXT    NOT NULL,
    attempts        INTEGER NOT NULL DEFAULT 0,
    claimed_at      TEXT,
    claim_token     TEXT
  )
  ''',

  // Pending work is read far more often than it is written, and always in seq order.
  'CREATE INDEX outbox_pending ON outbox (claimed_at, seq)',

  // Rejected observations are moved here, not deleted. A rejection means this build produced
  // something the contract does not allow, which is a bug worth seeing; deleting the evidence
  // would leave a study with an unexplained hole and no way to find out why.
  '''
  CREATE TABLE dead_letter (
    seq             INTEGER PRIMARY KEY,
    study_id        TEXT    NOT NULL,
    protocol_hash   TEXT    NOT NULL,
    subject         TEXT    NOT NULL,
    device_id       TEXT    NOT NULL,
    module          TEXT    NOT NULL,
    schema_uri      TEXT    NOT NULL,
    observed_at     TEXT    NOT NULL,
    clock_offset_ms INTEGER,
    payload         TEXT    NOT NULL,
    created_at      TEXT    NOT NULL,
    reason          TEXT    NOT NULL,
    detail          TEXT,
    rejected_at     TEXT    NOT NULL,
    surfaced        INTEGER NOT NULL DEFAULT 0
  )
  ''',

  // Small key/value store for install identity, the clock offset and the server watermark.
  'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
];
