/**
 * Server-side message deduplication (idempotency by message_id).
 *
 * TypeScript port of `lib/core/socket/protocol/message_dedup.dart`.
 *
 * Idempotency rule: a `message.send` carrying a message_id that was already
 * accepted is NOT re-persisted and NOT re-fanned-out; the server answers
 * with the ORIGINAL ack (same server_seq) so the retrying client converges.
 *
 * LRU window in process memory; production mapping: Redis `SET NX` with
 * 24h TTL per account (docs/SOCKET_SERVER_ARCHITECTURE.md §4).
 */
export class MessageDedup {
  readonly windowSize: number;
  private readonly seen = new Map<string, number>();
  private clockTick = 0;

  constructor(windowSize = 4096) {
    this.windowSize = windowSize;
  }

  /** Returns true if messageId is new (and remembers it). */
  accept(messageId: string): boolean {
    if (this.seen.has(messageId)) {
      this.seen.set(messageId, this.clockTick++);
      return false;
    }
    this.seen.set(messageId, this.clockTick++);
    if (this.seen.size > this.windowSize) this.evictOldest();
    return true;
  }

  /** True when the id is already known (without consuming). */
  contains(messageId: string): boolean {
    return this.seen.has(messageId);
  }

  private evictOldest(): void {
    let oldest: string | null = null;
    let oldestTick = Number.MAX_SAFE_INTEGER;
    for (const [id, tick] of this.seen) {
      if (tick < oldestTick) {
        oldestTick = tick;
        oldest = id;
      }
    }
    if (oldest !== null) this.seen.delete(oldest);
  }

  get remembered(): number {
    return this.seen.size;
  }
}
