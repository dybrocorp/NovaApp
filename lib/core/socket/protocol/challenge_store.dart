import 'dart:convert';
import 'dart:math';

/// REFERENCE implementation of the server-side anti-replay challenge store.
///
/// The repo does NOT contain a realtime server yet (audited: true). This
/// class is the executable specification every server MUST reproduce; the
/// protocol tests exercise the client against it, and
/// docs/SOCKET_SERVER_ARCHITECTURE.md maps it to Redis (SETEX + DEL).
///
/// Guarantees:
///   * challenges are 32 bytes of CSPRNG output, base64-encoded;
///   * each challenge is bound to one connection attempt
///     (socketKey + account + device);
///   * each challenge expires (default 60s);
///   * each challenge is SINGLE USE: consuming it deletes it, so a replayed
///     auth.response with the same challenge_id is rejected;
///   * a modified challenge (different bytes) fails signature verification.
class ChallengeStore {
  ChallengeStore({
    this.ttl = const Duration(seconds: 60),
    DateTime Function()? clock,
    Random? random,
  })  : _clock = clock ?? DateTime.now,
        _random = random ?? Random.secure();

  final Duration ttl;
  final DateTime Function() _clock;
  final Random _random;

  final Map<String, _IssuedChallenge> _challenges = {};

  /// Verdict of consuming a challenge.
  enum ConsumeResult { ok, unknownChallenge, expired, wrongAttempt }

  /// Issues a fresh challenge for a connection attempt.
  IssuedChallengeData issue({
    required String socketKey,
    required String accountId,
    required String deviceId,
  }) {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final challengeBase64 = base64Encode(bytes);
    final id = _randomId();
    final now = _clock();
    _challenges[id] = _IssuedChallenge(
      socketKey: socketKey,
      accountId: accountId,
      deviceId: deviceId,
      challengeBase64: challengeBase64,
      expiresAt: now.add(ttl),
    );
    _sweep();
    return IssuedChallengeData(
      challengeId: id,
      challengeBase64: challengeBase64,
      expiresAtMs: now.add(ttl).millisecondsSinceEpoch,
    );
  }

  /// Validates and consumes a challenge for an incoming auth.response.
  ///
  /// Single use: the challenge is ALWAYS removed once consumed — even when
  /// verification later fails — so a tampered attempt also burns it. On
  /// [ConsumeResult.ok] the challenge bytes are returned so the caller can
  /// verify the Ed25519 signature over them.
  ConsumeOutcome consume({
    required String challengeId,
    required String socketKey,
    required String accountId,
    required String deviceId,
  }) {
    final entry = _challenges[challengeId];
    if (entry == null) return const ConsumeOutcome(ConsumeResult.unknownChallenge);
    // Single use: remove FIRST so even a failed consume burns the challenge.
    _challenges.remove(challengeId);
    if (_clock().isAfter(entry.expiresAt)) {
      return const ConsumeOutcome(ConsumeResult.expired);
    }
    if (entry.socketKey != socketKey ||
        entry.accountId != accountId ||
        entry.deviceId != deviceId) {
      return const ConsumeOutcome(ConsumeResult.wrongAttempt);
    }
    return ConsumeOutcome(ConsumeResult.ok, entry.challengeBase64);
  }

  /// Drops expired entries (the Redis equivalent is key TTL expiry).
  void _sweep() {
    final now = _clock();
    _challenges.removeWhere((_, e) => now.isAfter(e.expiresAt));
  }

  String _randomId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// Number of live challenges (for tests/monitoring only).
  int get liveCount => _challenges.length;
}

/// Result of [ChallengeStore.consume]; carries the challenge bytes on ok.
class ConsumeOutcome {
  const ConsumeOutcome(this.result, [this.challengeBase64]);

  final ChallengeStore.ConsumeResult result;
  final String? challengeBase64;

  bool get isOk => result == ChallengeStore.ConsumeResult.ok;
}

class IssuedChallengeData {
  const IssuedChallengeData({
    required this.challengeId,
    required this.challengeBase64,
    required this.expiresAtMs,
  });

  final String challengeId;
  final String challengeBase64;
  final int expiresAtMs;

  Map<String, dynamic> toWire() => <String, dynamic>{
        'challenge_id': challengeId,
        'challenge': challengeBase64,
        'expires_at_ms': expiresAtMs,
      };
}

class _IssuedChallenge {
  const _IssuedChallenge({
    required this.socketKey,
    required this.accountId,
    required this.deviceId,
    required this.challengeBase64,
    required this.expiresAt,
  });

  final String socketKey;
  final String accountId;
  final String deviceId;
  final String challengeBase64;
  final DateTime expiresAt;
}
