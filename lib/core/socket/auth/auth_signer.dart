import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'auth_payloads.dart';

/// Builds and signs the `auth.response` payload.
///
/// Canonical signed message (v1) — the signature covers ALL identity
/// claims plus the challenge, so a valid signature for one device can
/// never be replayed as another device:
///
///   NOVA_AUTH_v1|<account_id>|<device_id>|<nova_id>|<challenge_id>|<challenge>
///
/// The server verifies the signature against the REGISTERED Ed25519 public
/// key of (account_id, device_id) — never against a key sent by the client.
class AuthSigner {
  const AuthSigner();

  static const String canonicalPrefix = 'NOVA_AUTH_v1';

  /// Canonical message that gets signed for a handshake attempt.
  static String canonicalMessage({
    required String accountId,
    required String deviceId,
    required String novaId,
    required String challengeId,
    required String challengeBase64,
  }) {
    return [
      canonicalPrefix,
      accountId,
      deviceId,
      novaId,
      challengeId,
      challengeBase64,
    ].join('|');
  }

  /// Builds the signed auth.response for [challenge]. Returns null when the
  /// identity material is incomplete (fail closed: never send a response
  /// that the server must reject anyway).
  Future<AuthResponsePayload?> buildResponse({
    required AuthChallenge challenge,
    required SimpleKeyPair identityKeyPair,
    required String accountId,
    required String deviceId,
    required String novaId,
    required DateTime now,
  }) async {
    if (!challenge.isValid ||
        challenge.isExpired(now: now) ||
        challenge.hasImplausibleExpiry(now: now)) {
      return null;
    }
    if (accountId.isEmpty || deviceId.isEmpty || novaId.isEmpty) {
      return null;
    }
    final message = canonicalMessage(
      accountId: accountId,
      deviceId: deviceId,
      novaId: novaId,
      challengeId: challenge.challengeId,
      challengeBase64: challenge.challengeBase64,
    );
    final signature = await Ed25519().sign(
      utf8.encode(message),
      keyPair: identityKeyPair,
    );
    return AuthResponsePayload(
      challengeId: challenge.challengeId,
      signatureBase64: base64Encode(signature.bytes),
      accountId: accountId,
      deviceId: deviceId,
      novaId: novaId,
      tsMs: now.millisecondsSinceEpoch,
    );
  }

  /// Reference verification used by the protocol tests and mirrored by the
  /// realtime server: verifies [signatureBase64] over the canonical message
  /// using [registeredPublicKey].
  static Future<bool> verifySignature({
    required String accountId,
    required String deviceId,
    required String novaId,
    required String challengeId,
    required String challengeBase64,
    required String signatureBase64,
    required List<int> registeredPublicKey,
  }) async {
    final message = canonicalMessage(
      accountId: accountId,
      deviceId: deviceId,
      novaId: novaId,
      challengeId: challengeId,
      challengeBase64: challengeBase64,
    );
    final publicKey = SimplePublicKey(
      registeredPublicKey,
      type: KeyPairType.ed25519,
    );
    try {
      return await Ed25519().verify(
        utf8.encode(message),
        signature: Signature(
          base64Decode(signatureBase64),
          publicKey: publicKey,
        ),
      );
      // Malformed base64 or malformed signature => invalid, not a crash.
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    }
  }
}
