/**
 * Server-side anti-replay challenge store.
 *
 * TypeScript port of `lib/core/socket/protocol/challenge_store.dart`
 * (executable specification, PASO 4). Same guarantees:
 *
 *   * challenges are 32 bytes of CSPRNG output, base64-encoded;
 *   * each challenge is bound to one connection attempt
 *     (socketKey + account + device);
 *   * each challenge expires (default 60s);
 *   * each challenge is SINGLE USE: consuming it deletes it, so a replayed
 *     auth.response with the same challenge_id is rejected;
 *   * a modified challenge (different bytes) fails signature verification.
 *
 * Deviation (documented in docs/SOCKET_SERVER_ARCHITECTURE.md §2): the
 * client contract issues the challenge immediately on connection, before
 * any account/device identity is known (there is no auth.hello on the
 * wire). The server therefore issues the challenge bound to the SOCKET
 * ONLY (wildcard account/device) and RE-BINDS it to the claimed
 * (account_id, device_id) when auth.response arrives — the documented
 * "generic challenge, re-bound on response" variant. All other guarantees
 * (single use, expiry, socket binding, CSPRNG bytes) are unchanged, and
 * `issueBound()` retains the fully-bound variant for internal use/tests.
 *
 * Production mapping: Redis `SETEX chal:<id> 60 <...>` + GETDEL.
 */
import { randomBytes } from 'node:crypto';

export const WILDCARD = '*';

export type ConsumeResult =
  | 'ok'
  | 'unknownChallenge'
  | 'expired'
  | 'wrongAttempt';

export interface IssuedChallengeData {
  challengeId: string;
  challengeBase64: string;
  expiresAtMs: number;
}

interface StoredChallenge {
  socketKey: string;
  accountId: string;
  deviceId: string;
  challengeBase64: string;
  expiresAtMs: number;
}

export class ChallengeStore {
  private readonly ttlMs: number;
  private readonly clock: () => number;
  private readonly challenges = new Map<string, StoredChallenge>();

  constructor(options: { ttlMs?: number; clock?: () => number } = {}) {
    this.ttlMs = options.ttlMs ?? 60_000;
    this.clock = options.clock ?? Date.now;
  }

  /** Issues a fresh challenge for a connection attempt. */
  issue(
    socketKey: string,
    accountId: string = WILDCARD,
    deviceId: string = WILDCARD,
  ): IssuedChallengeData {
    const challengeBase64 = randomBytes(32).toString('base64');
    const challengeId = randomBytes(16).toString('base64url');
    const now = this.clock();
    const expiresAtMs = now + this.ttlMs;
    this.challenges.set(challengeId, {
      socketKey,
      accountId,
      deviceId,
      challengeBase64,
      expiresAtMs,
    });
    this.sweep();
    return { challengeId, challengeBase64, expiresAtMs };
  }

  /** Fully-bound issue (the Dart reference variant). */
  issueBound(socketKey: string, accountId: string, deviceId: string): IssuedChallengeData {
    return this.issue(socketKey, accountId, deviceId);
  }

  /**
   * Re-binds a wildcard challenge to the claimed identity at
   * auth.response time. No-op (false) if the challenge does not exist,
   * is expired, or is already bound.
   */
  rebind(challengeId: string, accountId: string, deviceId: string): boolean {
    const entry = this.challenges.get(challengeId);
    if (!entry) return false;
    if (this.clock() > entry.expiresAtMs) return false;
    if (entry.accountId !== WILDCARD || entry.deviceId !== WILDCARD) {
      return false;
    }
    entry.accountId = accountId;
    entry.deviceId = deviceId;
    return true;
  }

  /**
   * Validates and consumes a challenge for an incoming auth.response.
   *
   * Single use: the challenge is ALWAYS removed once consumed — even when
   * verification later fails — so a tampered attempt also burns it. On
   * 'ok' the challenge bytes are returned so the caller can verify the
   * Ed25519 signature over them.
   */
  consume(input: {
    challengeId: string;
    socketKey: string;
    accountId: string;
    deviceId: string;
  }): { result: ConsumeResult; challengeBase64?: string } {
    const entry = this.challenges.get(input.challengeId);
    if (!entry) return { result: 'unknownChallenge' };
    // Single use: remove FIRST so even a failed consume burns the challenge.
    this.challenges.delete(input.challengeId);
    if (this.clock() > entry.expiresAtMs) {
      return { result: 'expired' };
    }
    if (
      entry.socketKey !== input.socketKey ||
      entry.accountId !== input.accountId ||
      entry.deviceId !== input.deviceId
    ) {
      return { result: 'wrongAttempt' };
    }
    return { result: 'ok', challengeBase64: entry.challengeBase64 };
  }

  /** Drops expired entries (the Redis equivalent is key TTL expiry). */
  private sweep(): void {
    const now = this.clock();
    for (const [id, entry] of this.challenges) {
      if (now > entry.expiresAtMs) this.challenges.delete(id);
    }
  }

  /** Number of live challenges (for tests/monitoring only). */
  get liveCount(): number {
    return this.challenges.size;
  }
}
