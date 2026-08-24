/**
 * Auth failure tracking + lockout.
 *
 * Implements the handshake limits from docs/SOCKET_SERVER_ARCHITECTURE.md §2:
 * "5/min por device e IP; lockout 2 min tras 5 fallos (Redis INCR+EXPIRE)".
 *
 * Failure counters are scoped by key (`device:<id>` and/or `ip:<addr>`,
 * configurable). Lockout is enforced BEFORE a challenge is consumed, so a
 * locked-out identity cannot burn challenges. Production mapping: Redis
 * INCR+EXPIRE; this in-memory tracker covers a single node.
 */
export class AuthFailureTracker {
  private readonly failures = new Map<string, { count: number; firstAtMs: number }>();
  private readonly lockoutThreshold: number;
  private readonly lockoutMs: number;
  private readonly windowMs: number;
  private readonly clock: () => number;

  constructor(options: {
    lockoutThreshold?: number;
    lockoutMs?: number;
    windowMs?: number;
    clock?: () => number;
  } = {}) {
    this.lockoutThreshold = options.lockoutThreshold ?? 5;
    this.lockoutMs = options.lockoutMs ?? 120_000;
    this.windowMs = options.windowMs ?? this.lockoutMs;
    this.clock = options.clock ?? Date.now;
  }

  private now(): number {
    return this.clock();
  }

  /** True while the scope key is locked out (too many recent failures). */
  isLocked(scopeKey: string): boolean {
    const entry = this.failures.get(scopeKey);
    if (!entry) return false;
    const now = this.now();
    if (now - entry.firstAtMs > this.windowMs) {
      this.failures.delete(scopeKey);
      return false;
    }
    return entry.count >= this.lockoutThreshold;
  }

  /** Records a failure for the scope key; returns the current count. */
  recordFailure(scopeKey: string): number {
    const now = this.now();
    const windowMs = this.windowMs;
    const existing = this.failures.get(scopeKey);
    if (!existing || now - existing.firstAtMs > windowMs) {
      this.failures.set(scopeKey, { count: 1, firstAtMs: now });
      return 1;
    }
    existing.count += 1;
    return existing.count;
  }

  /** Clears failures for a scope (e.g. after a successful handshake). */
  clear(scopeKey: string): void {
    this.failures.delete(scopeKey);
  }
}
