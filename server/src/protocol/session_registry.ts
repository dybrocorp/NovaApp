/**
 * Server-side session registry.
 *
 * TypeScript port of `lib/core/socket/protocol/session_registry.dart`
 * (PASO 4). After a successful handshake the server creates a session:
 *   * random 256-bit id;
 *   * TTL (default 24h) with sliding renewal on activity;
 *   * bound to (accountId, deviceId, novaId, socketKey);
 *   * revocable individually or by device;
 *   * exactly ONE live session per device — a reconnecting device evicts
 *     its previous session immediately and it can never be resurrected.
 *
 * Production mapping: Redis hash `sess:<id>` with sliding TTL + mirror in
 * the Supabase `sessions` table (see docs/SOCKET_SERVER_ARCHITECTURE.md §3).
 */
import { randomBytes } from 'node:crypto';

export type SessionValidation =
  | 'ok'
  | 'invalid'
  | 'expired'
  | 'revoked';

export interface RegisteredSession {
  sessionId: string;
  socketKey: string;
  accountId: string;
  deviceId: string;
  novaId: string;
  createdAtMs: number;
  expiresAtMs: number;
}

export class SessionRegistry {
  private readonly sessionTtlMs: number;
  private readonly clock: () => number;
  private readonly sessions = new Map<string, RegisteredSession>();

  constructor(options: { sessionTtlMs?: number; clock?: () => number } = {}) {
    this.sessionTtlMs = options.sessionTtlMs ?? 24 * 60 * 60 * 1000;
    this.clock = options.clock ?? Date.now;
  }

  /**
   * Creates a session after a verified handshake. Evicts any previous
   * live session of the SAME DEVICE first: one live session per device.
   * Returns the new session plus the evicted ones (so the caller can
   * disconnect their sockets).
   */
  create(input: {
    socketKey: string;
    accountId: string;
    deviceId: string;
    novaId: string;
  }): { session: RegisteredSession; evicted: RegisteredSession[] } {
    const evicted = this.evictByDevice(input.deviceId);
    const now = this.clock();
    const session: RegisteredSession = {
      sessionId: randomBytes(32).toString('base64url'), // 256-bit id
      socketKey: input.socketKey,
      accountId: input.accountId,
      deviceId: input.deviceId,
      novaId: input.novaId,
      createdAtMs: now,
      expiresAtMs: now + this.sessionTtlMs,
    };
    this.sessions.set(session.sessionId, session);
    return { session, evicted };
  }

  /**
   * Validates a session for event authorization. Sliding renewal on
   * success keeps active devices logged in without extending idle ones.
   */
  validate(sessionId: string, socketKey: string): SessionValidation {
    const session = this.sessions.get(sessionId);
    if (!session) return 'invalid';
    const now = this.clock();
    if (now > session.expiresAtMs) {
      this.sessions.delete(sessionId);
      return 'expired';
    }
    if (session.socketKey !== socketKey) return 'invalid';
    this.sessions.set(sessionId, { ...session, expiresAtMs: now + this.sessionTtlMs });
    return 'ok';
  }

  /** Revokes one session (logout of one socket). Returns the removed session. */
  revoke(sessionId: string): RegisteredSession | null {
    const session = this.sessions.get(sessionId) ?? null;
    this.sessions.delete(sessionId);
    return session;
  }

  /** Revokes every session of a device (device revoked / logout device). */
  revokeByDevice(deviceId: string): RegisteredSession[] {
    const doomed: RegisteredSession[] = [];
    for (const session of this.sessions.values()) {
      if (session.deviceId === deviceId) doomed.push(session);
    }
    for (const session of doomed) this.sessions.delete(session.sessionId);
    return doomed;
  }

  bySessionId(sessionId: string): RegisteredSession | null {
    return this.sessions.get(sessionId) ?? null;
  }

  /** True when the device has at least one live session. */
  deviceHasLiveSession(deviceId: string): boolean {
    for (const session of this.sessions.values()) {
      if (session.deviceId === deviceId) return true;
    }
    return false;
  }

  get liveCount(): number {
    return this.sessions.size;
  }

  private evictByDevice(deviceId: string): RegisteredSession[] {
    const evicted: RegisteredSession[] = [];
    for (const session of this.sessions.values()) {
      if (session.deviceId === deviceId) evicted.push(session);
    }
    for (const session of evicted) this.sessions.delete(session.sessionId);
    return evicted;
  }
}
