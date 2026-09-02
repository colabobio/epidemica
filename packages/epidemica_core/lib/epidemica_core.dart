/// Identity, enrollment, the observation outbox, sync and clock reconciliation.
///
/// Modules call [Outbox.record] and are done. Everything after that — batching, compression,
/// retry, deduplication, dead-lettering — is this package's problem, and the guarantee it offers
/// is narrow but firm: a recorded observation is delivered exactly once, or is visibly parked, but
/// is never quietly lost.
library;

export 'src/clock.dart';
export 'src/db/database.dart';
export 'src/enrollment.dart';
export 'src/identity.dart';
export 'src/modules/embedded_module.dart';
export 'src/modules/module_health.dart';
export 'src/outbox.dart';
export 'src/protocol_bundle.dart';
export 'src/state/participant_state.dart';
export 'src/state/state_channel.dart';
export 'src/sync/backoff.dart';
export 'src/sync/ingest_client.dart';
export 'src/sync/ingest_result.dart';
export 'src/sync/sync_service.dart';
export 'src/tokens.dart';
