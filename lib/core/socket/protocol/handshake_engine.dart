import '../auth/auth_signer.dart';
import 'challenge_store.dart';
import 'device_registry.dart';
import 'session_registry.dart';

/// EXECUTABLE SPECIFICATION of the server-side handshake.
///
/// This is NOT a server: the repo contains no realtime server (audited).
/// It encodes, in testable form, the exact verification sequence every
/// production realtime server MUST implement for `auth.response`:
///
///   1. payload shape                        -> AUTH_FAILED
///   2. device exists + ACTIVE               -> AUTH_FAILED (revoked included)
///   3. account_id/nova_id match the device  -> AUTH_FAILED
///   4. challenge exists, unexpired,
///      single-use, bound to THIS attempt    -> AUTH_FAILED
///   5. Ed25519 signature over the canonical
///      message with the REGISTERED key      -> AUTH_FAILED
///   6. create session (random id, TTL,
///      bound to account+device+socket)      -> auth.success
///
/// NOTE: steps 2-5 all answer AUTH_FAILED on the wire — a client (and any
/// attacker) cannot distinguish *why* it failed. The enum below is internal
/// so tests can assert the exact failing step.
class HandshakeEngine {
  HandshakeEngine({
    required this.devices,
    required this.challenges,
    required this.sessions,
  });

  final DeviceRegistry devices;
  final ChallengeStore challenges;
  final SessionRegistry sessions;

  /// Exact outcome of a handshake attempt (internal; see [wireFailureCode]).
  enum HandshakeOutcome {
    success,
    badPayload,
    deviceUnknownOrRevoked,
    challengeRejected,
    badSignature,
  }

  /// Wire-level failure code for an outcome (what a client may see).
  static String wireFailureCode(HandshakeOutcome outcome) {
    switch (outcome) {
      case HandshakeOutcome.success:
        return '';
      case HandshakeOutcome.badPayload:
      case HandshakeOutcome.deviceUnknownOrRevoked:
      case HandshakeOutcome.challengeRejected:
      case HandshakeOutcome.badSignature:
        return 'AUTH_FAILED';
    }
  }

  /// Processes an auth.response arriving on [socketKey].
  Future<HandshakeResult> handleAuthResponse({
    required String socketKey,
    required Map<String, dynamic> payload,
  }) async {
    // 1. Payload shape.
    if (payload['challenge_id'] is! String ||
        payload['signature'] is! String ||
        payload['account_id'] is! String ||
        payload['device_id'] is! String ||
        payload['nova_id'] is! String) {
      return const HandshakeResult(HandshakeOutcome.badPayload, null);
    }
    final accountId = payload['account_id'] as String;
    final deviceId = payload['device_id'] as String;
    final novaId = payload['nova_id'] as String;
    final challengeId = payload['challenge_id'] as String;
    final signature = payload['signature'] as String;

    // 2. Device exists, belongs to this account/nova id, and is ACTIVE
    //    (a REVOKED device lands on the same generic failure).
    final device = devices.byDeviceId(deviceId);
    if (device == null ||
        device.status != DeviceStatus.active ||
        device.accountId != accountId ||
        device.novaId != novaId) {
      return const HandshakeResult(
        HandshakeOutcome.deviceUnknownOrRevoked,
        null,
      );
    }

    // 3. Challenge: exists, unexpired, single-use, bound to this attempt.
    final consumed = challenges.consume(
      challengeId: challengeId,
      socketKey: socketKey,
      accountId: accountId,
      deviceId: deviceId,
    );
    if (!consumed.isOk || consumed.challengeBase64 == null) {
      return const HandshakeResult(HandshakeOutcome.challengeRejected, null);
    }

    // 4. Ed25519 signature over the canonical message with the REGISTERED
    //    public key (never a key sent by the client).
    final signatureOk = await AuthSigner.verifySignature(
      accountId: accountId,
      deviceId: deviceId,
      novaId: novaId,
      challengeId: challengeId,
      challengeBase64: consumed.challengeBase64!,
      signatureBase64: signature,
      registeredPublicKey: device.ed25519PublicKey,
    );
    if (!signatureOk) {
      return const HandshakeResult(HandshakeOutcome.badSignature, null);
    }

    // 5. Create the authenticated session bound to this socket.
    final session = sessions.create(
      socketKey: socketKey,
      accountId: accountId,
      deviceId: deviceId,
      novaId: novaId,
    );
    return HandshakeResult(HandshakeOutcome.success, session);
  }
}

/// Outcome + created session (null unless success).
class HandshakeResult {
  const HandshakeResult(this.outcome, this.session);

  final HandshakeEngine.HandshakeOutcome outcome;
  final RegisteredSession? session;
}
