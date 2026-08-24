import 'dart:math';

/// Token-bucket rate limiter used on the client for every outgoing event
/// domain (auth, message, typing, signaling, sync, aggregate).
///
/// The server applies its own limits (see docs/SOCKET_SECURITY.md); this
/// client-side limiter exists so a bug or a retry storm never turns into
/// abuse, and to fail fast instead of buffering unbounded traffic.
///
/// Algorithm: classic token bucket.
///   * capacity `burst` tokens;
///   * refills at `perMinute` tokens/minute, continuously;
///   * `allow()` consumes 1 token or returns false (never goes negative).
///
/// The clock is injectable so tests are deterministic.
class TokenBucketRateLimiter {
  TokenBucketRateLimiter({
    required this.burst,
    required this.perMinute,
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        _tokens = burst.toDouble();

  /// Maximum burst size (bucket capacity).
  final int burst;

  /// Sustained refill rate in tokens per minute.
  final double perMinute;

  final DateTime Function() _clock;
  double _tokens;
  DateTime? _lastRefill;

  /// Tokens available right now (0..burst), recomputing elapsed refill.
  double get availableTokens {
    _refill();
    return _tokens;
  }

  /// Consumes one token if available; returns true when allowed.
  bool allow() => allowN(1);

  /// Consumes [n] tokens if available.
  bool allowN(int n) {
    _refill();
    if (n > burst || _tokens < n) return false;
    _tokens -= n;
    return true;
  }

  /// Drops all tokens (penalty after a protocol violation).
  void drain() => _tokens = 0.0;

  void _refill() {
    final now = _clock();
    if (_lastRefill == null) {
      _lastRefill = now;
      return;
    }
    final elapsedMs = now.difference(_lastRefill!).inMilliseconds;
    if (elapsedMs <= 0) return;
    final refill = elapsedMs * perMinute / 60000;
    _tokens = min(burst.toDouble(), _tokens + refill);
    _lastRefill = now;
  }
}

/// Bundles the per-domain client-side limiters used by the socket layer.
///
/// Uses the presets from SocketRateLimitPresets. A single aggregate limiter
/// caps everything as a safety net.
class SocketRateLimiters {
  SocketRateLimiters({DateTime Function()? clock})
      : auth = TokenBucketRateLimiter(
          burst: SocketRateLimitPresets.authPerMinute,
          perMinute: SocketRateLimitPresets.authPerMinute.toDouble(),
          clock: clock,
        ),
        message = TokenBucketRateLimiter(
          burst: SocketRateLimitPresets.messagePerMinute,
          perMinute: SocketRateLimitPresets.messagePerMinute.toDouble(),
          clock: clock,
        ),
        typing = TokenBucketRateLimiter(
          burst: SocketRateLimitPresets.typingPerMinute,
          perMinute: SocketRateLimitPresets.typingPerMinute.toDouble(),
          clock: clock,
        ),
        signaling = TokenBucketRateLimiter(
          burst: SocketRateLimitPresets.signalingPerMinute,
          perMinute: SocketRateLimitPresets.signalingPerMinute.toDouble(),
          clock: clock,
        ),
        sync = TokenBucketRateLimiter(
          burst: SocketRateLimitPresets.syncPerMinute,
          perMinute: SocketRateLimitPresets.syncPerMinute.toDouble(),
          clock: clock,
        ),
        presence = TokenBucketRateLimiter(
          burst: SocketRateLimitPresets.presencePerMinute,
          perMinute: SocketRateLimitPresets.presencePerMinute.toDouble(),
          clock: clock,
        ),
        aggregate = TokenBucketRateLimiter(
          burst: SocketRateLimitPresets.totalEventsPerMinute,
          perMinute: SocketRateLimitPresets.totalEventsPerMinute.toDouble(),
          clock: clock,
        );

  final TokenBucketRateLimiter auth;
  final TokenBucketRateLimiter message;
  final TokenBucketRateLimiter typing;
  final TokenBucketRateLimiter signaling;
  final TokenBucketRateLimiter sync;
  final TokenBucketRateLimiter presence;
  final TokenBucketRateLimiter aggregate;
}
