/// Typed payloads for the `auth.*` handshake.
///
/// Wire contract (v1):
///
///   auth.challenge (S->C):
///     { challenge_id, challenge, expires_at_ms }
///       challenge        — base64, >= 32 bytes of CSPRNG output
///       challenge_id     — opaque server identifier for this attempt
///       expires_at_ms    — server epoch ms; client sanity-checks it
///
///   auth.response (C->S):
///     { challenge_id, signature, account_id, device_id, nova_id, ts_ms }
///       signature signs the canonical message built by AuthSigner:
///         'NOVA_AUTH_v1|<account_id>|<device_id>|<nova_id>|<challenge_id>|<challenge>'
///       The public key is NOT sent: the server uses the REGISTERED key for
///       the (account_id, device_id) pair. Sending a key would let anyone
///       claim one; binding to the registered key prevents impersonation.
///
///   auth.success (S->C):
///     { session_id, account_id, device_id, nova_id, expires_at_ms }
///       session_id — opaque, random, server-generated; used for revocation.
///       The client sends NO signature afterwards: every event is authorized
///       against the session bound to this socket.
///
///   auth.failure (S->C):
///     { code }  — generic code only (never says WHICH check failed).
import 'dart:convert';

/// Parse/validate an inbound auth.challenge.
class AuthChallenge {
  const AuthChallenge({
    required this.challengeId,
    required this.challengeBase64,
    required this.expiresAtMs,
  });

  factory AuthChallenge.tryParse(dynamic data) {
    if (data is! Map) return const AuthChallenge.invalid();
    final id = data['challenge_id'];
    final challenge = data['challenge'];
    final expires = data['expires_at_ms'];
    if (id is! String || id.isEmpty || challenge is! String) {
      return const AuthChallenge.invalid();
    }
    if (expires is! int || expires <= 0) {
      return const AuthChallenge.invalid();
    }
    // Challenge must decode and be >= 32 bytes of entropy.
    final bytes = base64TryDecode(challenge);
    if (bytes == null || bytes.length < 32) {
      return const AuthChallenge.invalid();
    }
    return AuthChallenge(
      challengeId: id,
      challengeBase64: challenge,
      expiresAtMs: expires,
    );
  }

  const AuthChallenge.invalid()
      : challengeId = '',
        challengeBase64 = '',
        expiresAtMs = 0;

  final String challengeId;
  final String challengeBase64;
  final int expiresAtMs;

  /// A challenge parsed but marked invalid has an empty id.
  bool get isValid => challengeId.isNotEmpty && challengeBase64.isNotEmpty;

  /// Client-side sanity check: a challenge claiming to expire in the past
  /// (or absurdly far in the future) is rejected locally before signing.
  bool isExpired({required DateTime now}) =>
      expiresAtMs <= now.millisecondsSinceEpoch;

  /// Rejects challenges whose claimed expiry is implausible (> 10 minutes
  /// from now). Real challenges live ~30-60 seconds.
  bool hasImplausibleExpiry({required DateTime now}) =>
      expiresAtMs >
      now.millisecondsSinceEpoch + const Duration(minutes: 10).inMilliseconds;
}

/// Payload for auth.response (client -> server). Built by [AuthSigner].
class AuthResponsePayload {
  const AuthResponsePayload({
    required this.challengeId,
    required this.signatureBase64,
    required this.accountId,
    required this.deviceId,
    required this.novaId,
    required this.tsMs,
  });

  final String challengeId;
  final String signatureBase64;
  final String accountId;
  final String deviceId;
  final String novaId;
  final int tsMs;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'challenge_id': challengeId,
        'signature': signatureBase64,
        'account_id': accountId,
        'device_id': deviceId,
        'nova_id': novaId,
        'ts_ms': tsMs,
      };
}

/// Successful handshake result. The session is opaque to the client.
class AuthSuccess {
  const AuthSuccess({
    required this.sessionId,
    required this.accountId,
    required this.deviceId,
    required this.novaId,
    required this.expiresAtMs,
  });

  factory AuthSuccess.tryParse(dynamic data) {
    if (data is! Map) return const AuthSuccess.invalid();
    final session = data['session_id'];
    final account = data['account_id'];
    final device = data['device_id'];
    final nova = data['nova_id'];
    final expires = data['expires_at_ms'];
    if (session is! String ||
        session.isEmpty ||
        account is! String ||
        device is! String ||
        nova is! String ||
        expires is! int) {
      return const AuthSuccess.invalid();
    }
    return AuthSuccess(
      sessionId: session,
      accountId: account,
      deviceId: device,
      novaId: nova,
      expiresAtMs: expires,
    );
  }

  const AuthSuccess.invalid()
      : sessionId = '',
        accountId = '',
        deviceId = '',
        novaId = '',
        expiresAtMs = 0;

  final String sessionId;
  final String accountId;
  final String deviceId;
  final String novaId;
  final int expiresAtMs;

  bool get isValid => sessionId.isNotEmpty;

  bool isExpired({required DateTime now}) =>
      expiresAtMs <= now.millisecondsSinceEpoch;
}

/// Generic, non-enumerable failure codes. The server MUST answer with
/// AUTH_FAILED for every handshake rejection (signature mismatch, unknown
/// device, revoked device, bad challenge...) so attackers learn nothing
/// about which check failed. RATE_LIMITED is the only distinct code because
/// honest clients need to back off.
enum SocketAuthFailureCode {
  authFailed,
  rateLimited,
  deviceRevoked,
}

SocketAuthFailureCode parseAuthFailureCode(dynamic data) {
  final code = data is Map ? data['code'] : null;
  if (code == 'RATE_LIMITED') return SocketAuthFailureCode.rateLimited;
  if (code == 'DEVICE_REVOKED') return SocketAuthFailureCode.deviceRevoked;
  return SocketAuthFailureCode.authFailed;
}

/// base64 decode that returns null instead of throwing.
List<int>? base64TryDecode(String input) {
  try {
    return base64.decode(input);
    // Ignored: malformed base64 must not crash the handshake; the challenge
    // is treated as invalid instead.
  } on FormatException {
    return null;
  }
}
