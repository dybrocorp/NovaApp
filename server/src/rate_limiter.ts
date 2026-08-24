/**
 * Token-bucket rate limiter — server mirror of
 * `lib/core/socket/rate_limiter.dart` (PASO 4).
 *
 *   * capacity `burst` tokens;
 *   * refills at `perMinute` tokens/minute, continuously;
 *   * allow() consumes 1 token or returns false (never goes negative);
 *   * drain() drops all tokens (penalty after a protocol violation).
 *
 * Per-socket buckets live in process memory (single node). Multi-node
 * mapping (Redis Lua) is PASO 6 — see docs/SOCKET_SERVER_ARCHITECTURE.md §7.
 */

export class TokenBucketRateLimiter {
  readonly burst: number;
  readonly perMinute: number;
  private tokens: number;
  private lastRefillMs: number | null = null;
  private readonly clockFn?: () => number;

  constructor(options: { burst: number; perMinute: number; clock?: () => number }) {
    this.burst = options.burst;
    this.perMinute = options.perMinute;
    this.tokens = options.burst;
    this.clockFn = options.clock;
  }

  private nowMs(): number {
    return this.clockFn ? this.clockFn() : Date.now();
  }

  private refill(): void {
    const now = this.nowMs();
    if (this.lastRefillMs === null) {
      this.lastRefillMs = now;
      return;
    }
    const elapsedMs = now - this.lastRefillMs;
    if (elapsedMs <= 0) return;
    const refill = (elapsedMs * this.perMinute) / 60_000;
    this.tokens = Math.min(this.burst, this.tokens + refill);
    this.lastRefillMs = now;
  }

  /** Tokens available right now (0..burst), recomputing elapsed refill. */
  availableTokens(): number {
    this.refill();
    return this.tokens;
  }

  /** Consumes one token if available; returns true when allowed. */
  allow(): boolean {
    return this.allowN(1);
  }

  /** Consumes n tokens if available. */
  allowN(n: number): boolean {
    this.refill();
    if (n > this.burst || this.tokens < n) return false;
    this.tokens -= n;
    return true;
  }

  /** Drops all tokens (penalty after a protocol violation). */
  drain(): void {
    this.tokens = 0;
  }
}

/** Per-domain limiters bound to one socket (server side). */
export interface DomainRateLimiters {
  auth: TokenBucketRateLimiter;
  message: TokenBucketRateLimiter;
  typing: TokenBucketRateLimiter;
  signaling: TokenBucketRateLimiter;
  sync: TokenBucketRateLimiter;
  presence: TokenBucketRateLimiter;
  aggregate: TokenBucketRateLimiter;
}

export function createDomainRateLimiters(
  limits: {
    authPerMinute: number;
    messagePerMinute: number;
    typingPerMinute: number;
    signalingPerMinute: number;
    syncPerMinute: number;
    presencePerMinute: number;
    totalEventsPerMinute: number;
  },
  clock?: () => number,
): DomainRateLimiters {
  const make = (perMinute: number) =>
    new TokenBucketRateLimiter({ burst: perMinute, perMinute, clock });
  return {
    auth: make(limits.authPerMinute),
    message: make(limits.messagePerMinute),
    typing: make(limits.typingPerMinute),
    signaling: make(limits.signalingPerMinute),
    sync: make(limits.syncPerMinute),
    presence: make(limits.presencePerMinute),
    aggregate: make(limits.totalEventsPerMinute),
  };
}
