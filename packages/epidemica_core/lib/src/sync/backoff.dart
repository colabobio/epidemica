import 'dart:math';

/// Exponential backoff with full jitter.
///
/// Jitter is not decoration. A field site's devices come back onto the network together when the
/// building's wifi returns, and a deterministic schedule would have them retry in lockstep,
/// converting one outage into a self-inflicted thundering herd against the study server.
class Backoff {
  Backoff({
    this.initial = const Duration(seconds: 2),
    this.maximum = const Duration(minutes: 30),
    this.factor = 2.0,
    Random? random,
  }) : _random = random ?? Random();

  final Duration initial;
  final Duration maximum;
  final double factor;
  final Random _random;

  /// Delay before attempt [attempt], counting the first retry as 1.
  Duration delayFor(int attempt) {
    if (attempt <= 0) return Duration.zero;
    final exponential = initial.inMilliseconds * pow(factor, attempt - 1);
    final capped = min(exponential.toDouble(), maximum.inMilliseconds.toDouble());
    // Full jitter: uniform in [0, capped] rather than capped ± a little, which is what actually
    // spreads a synchronised fleet.
    return Duration(milliseconds: _random.nextInt(capped.toInt() + 1));
  }

  /// The server's own instruction wins over any local schedule; it knows what it is protecting.
  Duration nextDelay(int attempt, {Duration? retryAfter}) {
    if (retryAfter != null) {
      return retryAfter > maximum ? maximum : retryAfter;
    }
    return delayFor(attempt);
  }
}
