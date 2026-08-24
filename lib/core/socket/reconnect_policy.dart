import 'dart:math';

/// Reconnection backoff policy: exponential growth + FULL jitter, bounded.
///
/// The Socket.IO library auto-reconnection is disabled (see SocketConfig);
/// this policy is the single source of truth for reconnect timing.
///
/// Design (documented in docs/SOCKET_ARCHITECTURE.md):
///   * Base delay:        1s
///   * Multiplier:        x2 per attempt (exponential)
///   * Hard cap:          30s (mobile radio + battery friendly)
///   * Jitter:            FULL jitter — delay = uniform(0, min(cap, base*2^n))
///                        Full jitter avoids thundering-herd reconnect storms
///                        when a server or a mobile cell comes back.
///   * Max attempts:      12 in a row while offline. After that the client
///                        STOPS (no infinite loops) and waits for either
///                        connectivity to change (network switch) or an
///                        explicit `reconnect()` from the app.
///   * Reset:             on successful authentication, or when connectivity
///                        is regained after a known outage.
class ReconnectPolicy {
  ReconnectPolicy({
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.maxAttempts = 12,
    double Function()? jitterRandom,
  }) : _jitterRandom = jitterRandom ?? _defaultRandom;

  static double _defaultRandom() {
    final rng = Random.secure();
    return rng.nextDouble();
  }

  final Duration baseDelay;
  final Duration maxDelay;
  final int maxAttempts;
  final double Function() _jitterRandom;

  int _attempt = 0;

  /// Attempts since the last successful authentication (0-based).
  int get attempt => _attempt;

  /// True when the policy has exhausted [maxAttempts] consecutive retries
  /// and the client must stop scheduling automatic reconnections.
  bool get exhausted => _attempt >= maxAttempts;

  /// Computes the delay to wait before the NEXT reconnection attempt,
  /// and advances the attempt counter.
  Duration nextDelay() {
    if (exhausted) return Duration.zero;
    final capped = _cappedExponential(_attempt);
    _attempt++;
    // Full jitter: uniform in [0, capped].
    final jitteredMs = (_jitterRandom() * capped.inMilliseconds).round();
    return Duration(milliseconds: jitteredMs);
  }

  /// Delay preview WITHOUT advancing the counter (for logging/UI).
  Duration peekDelay() {
    if (exhausted) return Duration.zero;
    return _cappedExponential(_attempt);
  }

  /// Resets the backoff after success or a known-connectivity-restored event.
  void reset() => _attempt = 0;

  /// Marks one attempt as consumed without computing a delay (used when a
  /// reconnect is triggered immediately by a connectivity event).
  void countAttempt() {
    if (!exhausted) {
      _attempt++;
    }
  }

  Duration _cappedExponential(int attempt) {
    var ms = baseDelay.inMilliseconds;
    for (var i = 0; i < attempt; i++) {
      ms *= 2;
      if (ms >= maxDelay.inMilliseconds) {
        return maxDelay;
      }
    }
    return Duration(milliseconds: ms);
  }
}
