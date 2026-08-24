/**
 * Server-side handshake engine.
 *
 * TypeScript port of `lib/core/socket/protocol/handshake_engine.dart`
 * (PASO 4). Encodes the exact verification sequence for `auth.response`:
 *
 *   1. payload shape                        -> AUTH_FAILED
 *   2. device exists + ACTIVE               -> AUTH_FAILED (revoked included)
 *   3. account_id/nova_id match the device  -> AUTH_FAILED
 *   4. challenge exists, unexpired,
 *      single-use, bound to THIS attempt    -> AUTH_FAILED
 *   5. Ed25519 signature over the canonical
 *      message with the REGISTERED key      -> AUTH_FAILED
 *   6. create session (random id, TTL,
 *      bound to account+device+socket)      -> auth.success
 *
 * Steps 2-5 all answer AUTH_FAILED on the wire — a client (and any
 * attacker) cannot distinguish *why* it failed. The enum below is internal
 * so tests can assert the exact failing step.
 */
import { verifyAuthSignature } from '../canonical.js';
import type { DeviceRegistry } from './device_registry.js';
import type { ChallengeStore } from './challenge_store.js';
import type { SessionRegistry, RegisteredSession } from './session_registry.js';

export enum HandshakeOutcome {
  success = 'success',
  badPayload = 'badPayload',
  deviceUnknownOrRevoked = 'deviceUnknownOrRevoked',
  challengeRejected = 'challengeRejected',
  badSignature = 'badSignature',
}

export interface HandshakeResult {
  outcome: HandshakeOutcome;
  session: RegisteredSession | null;
  /** Sessions evicted by this successful handshake (same device reconnected). */
  evicted: RegisteredSession[];
}

/** Wire-level failure code for an outcome (what a client may see). */
export function wireFailureCode(outcome: HandshakeOutcome): string {
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

export class HandshakeEngine {
  constructor(
    private readonly devices: DeviceRegistry,
    private readonly challenges: ChallengeStore,
    private readonly sessions: SessionRegistry,
  ) {}

  /**
   * Processes an auth.response arriving on `socketKey`.
   *
   * `rebindWildcardChallenge` implements the documented connect-time
   * variant: the challenge was issued bound only to the socket, and is
   * re-bound to the claimed (account, device) right before consuming it
   * (docs/SOCKET_SERVER_ARCHITECTURE.md §2). Single use, expiry, socket
   * binding and signature binding are all still enforced.
   */
  async handleAuthResponse(input: {
    socketKey: string;
    payload: Record<string, unknown>;
    rebindWildcardChallenge?: boolean;
  }): Promise<HandshakeResult> {
    const failure = (outcome: HandshakeOutcome): HandshakeResult => ({
      outcome,
      session: null,
      evicted: [],
    });

    // 1. Payload shape.
    const { payload } = input;
    if (
      typeof payload['challenge_id'] !== 'string' ||
      typeof payload['signature'] !== 'string' ||
      typeof payload['account_id'] !== 'string' ||
      typeof payload['device_id'] !== 'string' ||
      typeof payload['nova_id'] !== 'string'
    ) {
      return failure(HandshakeOutcome.badPayload);
    }
    const accountId = payload['account_id'];
    const deviceId = payload['device_id'];
    const novaId = payload['nova_id'];
    const challengeId = payload['challenge_id'];
    const signature = payload['signature'];

    // 2. Device exists, belongs to this account/nova id, and is ACTIVE
    //    (a REVOKED device lands on the same generic failure).
    const device = this.devices.byDeviceId(deviceId);
    if (
      !device ||
      device.status !== 'active' ||
      device.accountId !== accountId ||
      device.novaId !== novaId
    ) {
      return failure(HandshakeOutcome.deviceUnknownOrRevoked);
    }

    // 3. Challenge: exists, unexpired, single-use, bound to this attempt.
    if (input.rebindWildcardChallenge ?? false) {
      this.challenges.rebind(challengeId, accountId, deviceId);
    }
    const consumed = this.challenges.consume({
      challengeId,
      socketKey: input.socketKey,
      accountId,
      deviceId,
    });
    if (consumed.result !== 'ok' || consumed.challengeBase64 === undefined) {
      return failure(HandshakeOutcome.challengeRejected);
    }

    // 4. Ed25519 signature over the canonical message with the REGISTERED
    //    public key (never a key sent by the client).
    const signatureOk = verifyAuthSignature({
      accountId,
      deviceId,
      novaId,
      challengeId,
      challengeBase64: consumed.challengeBase64,
      signatureBase64: signature,
      registeredPublicKey: device.ed25519PublicKey,
    });
    if (!signatureOk) {
      return failure(HandshakeOutcome.badSignature);
    }

    // 5. Create the authenticated session bound to this socket.
    const { session, evicted } = this.sessions.create({
      socketKey: input.socketKey,
      accountId,
      deviceId,
      novaId,
    });
    return { outcome: HandshakeOutcome.success, session, evicted };
  }
}
