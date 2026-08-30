/**
 * RealtimeStore — hot state owned by the realtime tier:
 * per-conversation sequence cursors, persisted (opaque) message envelopes,
 * the event log that backs sync.response, and presence.
 *
 * The server only ever stores CIPHERTEXT plus server-side metadata
 * (server_seq, received_at) — it MUST NOT be able to decrypt content.
 *
 * Two DIFFERENT monotonic counters exist per conversation and must not be
 * confused (FASE 0.5 §8/§15):
 *
 *   server_seq — ordering authority for MESSAGES. Assigned by
 *                `nextSeq()` on message.send. Receipts reference the
 *                server_seq of the message they talk about.
 *   log_seq    — ordering authority for the EVENT LOG that backs sync.
 *                Assigned by `appendEvent()` to every event (messages AND
 *                receipts). It is the sync cursor.
 *
 * Why two: a delivered/read receipt carries the server_seq of an OLDER
 * message. If sync paginated on server_seq, a client whose cursor was
 * already past that message would never receive the receipt — state would
 * silently diverge after a reconnect. Paginating the log on its own
 * monotonic log_seq makes every event recoverable exactly once.
 *
 * Backends: MemoryRealtimeStore (default, single node) and
 * SupabaseRealtimeStore (store/supabase_store.ts). A Redis-backed variant
 * (INCR cursors, TTL presence, event streams) is NOT implemented — see
 * docs/REALTIME_PRODUCTION_CHECKLIST.md.
 */

export interface StoredMessage {
  messageId: string;
  conversationId: string;
  senderAccountId: string;
  senderDeviceId: string;
  /** Opaque E2EE ciphertext (base64). Never plaintext. */
  ciphertextBase64: string;
  headerType: string;
  serverSeq: number;
  receivedAtMs: number;
  clientTimestampMs?: number;
  /** FASE 1 §22: server-enforced disappearing time (epoch ms). */
  expiresAtMs?: number;
  /** FASE 1 §21: deleted-for-everyone / expired ⇒ ciphertext purged. */
  redacted?: boolean;
}

export type RealtimeEventType =
  | 'message.new'
  | 'message.delivered'
  | 'message.read'
  /* FASE 1: tombstones (replayable history — never resurrects ciphertext) */
  | 'message.deleted'
  | 'message.expired';

export interface RedactOutcome {
  redacted: number;
  /** True when sender-owned copies exist but are ALREADY redacted
   *  (idempotent repeat). */
  already?: boolean;
  tombstoneLogSeq?: number;
  tombstoneServerSeq?: number;
}

export interface ExpiryHit {
  conversationId: string;
  messageId: string;
  logSeq: number;
}

/** An event as APPENDED by a handler (log_seq is assigned by the store). */
export interface AppendableEvent {
  conversationId: string;
  type: RealtimeEventType;
  /** server_seq of the message this event refers to. */
  serverSeq: number;
  atMs: number;
  payload: Record<string, unknown>;
}

/** An event as STORED / replayed (carries its assigned log_seq). */
export interface StoredEvent extends AppendableEvent {
  logSeq: number;
}

export interface PresenceRecord {
  accountId: string;
  status: 'online' | 'offline';
  lastSeenMs: number;
}

export interface RealtimeStore {
  /** INCR cursor:<conversation_id> — monotonic per-conversation MESSAGE seq. */
  nextSeq(conversationId: string): Promise<number>;
  latestSeq(conversationId: string): Promise<number>;

  persistMessage(message: StoredMessage): Promise<void>;
  findMessage(messageId: string): Promise<StoredMessage | null>;

  /** FASE 1 §21/§22: redact every sender-owned per-device copy of one
   *  logical message, rewrite the stored log entry so sync replay yields a
   *  tombstone instead of ciphertext, and append the tombstone event. */
  redactMessages(
    conversationId: string,
    messageId: string,
    byAccountId: string,
    reason: 'deleted' | 'expired',
    atMs: number,
  ): Promise<RedactOutcome>;
  /** FASE 1 §22: redact all messages whose expires_at_ms elapsed. Returns
   *  one hit per (conversation, logical id) for room fan-out. */
  purgeExpiredMessages(nowMs: number): Promise<ExpiryHit[]>;

  /** Appends to the per-conversation event log; returns the new log_seq. */
  appendEvent(event: AppendableEvent): Promise<number>;
  /** Replays log events with log_seq > lastLogSeq, ascending. */
  eventsSince(conversationId: string, lastLogSeq: number, limit: number): Promise<StoredEvent[]>;
  /** Highest assigned log_seq (the sync cursor when fully caught up). */
  latestLogSeq(conversationId: string): Promise<number>;

  getPresence(accountId: string): Promise<PresenceRecord | null>;
  setPresence(record: PresenceRecord): Promise<void>;
}

export class MemoryRealtimeStore implements RealtimeStore {
  private readonly cursors = new Map<string, number>();
  private readonly logCursors = new Map<string, number>();
  private readonly messages = new Map<string, StoredMessage>();
  private readonly eventLog = new Map<string, StoredEvent[]>();
  private readonly presence = new Map<string, PresenceRecord>();

  async nextSeq(conversationId: string): Promise<number> {
    const next = (this.cursors.get(conversationId) ?? 0) + 1;
    this.cursors.set(conversationId, next);
    return next;
  }

  async latestSeq(conversationId: string): Promise<number> {
    return this.cursors.get(conversationId) ?? 0;
  }

  async persistMessage(message: StoredMessage): Promise<void> {
    this.messages.set(message.messageId, { ...message });
  }

  async findMessage(messageId: string): Promise<StoredMessage | null> {
    return this.messages.get(messageId) ?? null;
  }

  async redactMessages(
    conversationId: string,
    messageId: string,
    byAccountId: string,
    reason: 'deleted' | 'expired',
    atMs: number,
  ): Promise<RedactOutcome> {
    const logical = (key: string): boolean =>
      key === messageId || key.startsWith(`${messageId}#`);
    let redacted = 0;
    let already = false;
    let maxSeq = 0;
    for (const [key, msg] of [...this.messages]) {
      if (msg.conversationId !== conversationId || !logical(key)) continue;
      if (msg.senderAccountId !== byAccountId) continue;
      if (msg.redacted) {
        already = true;
        continue;
      }
      this.messages.set(key, { ...msg, redacted: true, ciphertextBase64: '' });
      redacted += 1;
      if (msg.serverSeq > maxSeq) maxSeq = msg.serverSeq;
    }
    if (redacted === 0) return { redacted: 0, already };
    // Rewrite the ORIGINAL log entry: a late-syncing device must receive
    // the tombstone view, never the (now destroyed) ciphertext.
    const log = this.eventLog.get(conversationId) ?? [];
    for (let i = 0; i < log.length; i++) {
      const ev = log[i];
      if (ev.type === 'message.new' && ev.payload['message_id'] === messageId) {
        log[i] = {
          ...ev,
          payload: {
            ...ev.payload,
            ciphertext: null,
            deleted: true,
            deleted_reason: reason,
            deleted_at_ms: atMs,
          },
        };
      }
    }
    const tombstoneLogSeq = await this.appendEvent({
      conversationId,
      type: reason === 'deleted' ? 'message.deleted' : 'message.expired',
      serverSeq: maxSeq,
      atMs,
      payload: {
        message_id: messageId,
        conversation_id: conversationId,
        ...(reason === 'deleted' ? { by_account_id: byAccountId } : {}),
      },
    });
    return { redacted, tombstoneLogSeq, tombstoneServerSeq: maxSeq };
  }

  async purgeExpiredMessages(nowMs: number): Promise<ExpiryHit[]> {
    const hits: ExpiryHit[] = [];
    const seen = new Set<string>();
    for (const [key, msg] of [...this.messages]) {
      if (msg.redacted) continue;
      if (msg.expiresAtMs === undefined || msg.expiresAtMs > nowMs) continue;
      const logicalId = key.split('#')[0];
      const dedupe = `${msg.conversationId}|${logicalId}`;
      if (seen.has(dedupe)) continue;
      seen.add(dedupe);
      const out = await this.redactMessages(
        msg.conversationId,
        logicalId,
        msg.senderAccountId,
        'expired',
        nowMs,
      );
      if (out.redacted > 0) {
        hits.push({
          conversationId: msg.conversationId,
          messageId: logicalId,
          logSeq: out.tombstoneLogSeq ?? 0,
        });
      }
    }
    return hits;
  }

  async appendEvent(event: AppendableEvent): Promise<number> {
    const logSeq = (this.logCursors.get(event.conversationId) ?? 0) + 1;
    this.logCursors.set(event.conversationId, logSeq);
    const log = this.eventLog.get(event.conversationId) ?? [];
    log.push({ ...event, logSeq });
    this.eventLog.set(event.conversationId, log);
    return logSeq;
  }

  async eventsSince(
    conversationId: string,
    lastLogSeq: number,
    limit: number,
  ): Promise<StoredEvent[]> {
    const log = this.eventLog.get(conversationId) ?? [];
    return log
      .filter((event) => event.logSeq > lastLogSeq)
      .sort((a, b) => a.logSeq - b.logSeq)
      .slice(0, limit);
  }

  async latestLogSeq(conversationId: string): Promise<number> {
    return this.logCursors.get(conversationId) ?? 0;
  }

  async getPresence(accountId: string): Promise<PresenceRecord | null> {
    return this.presence.get(accountId) ?? null;
  }

  async setPresence(record: PresenceRecord): Promise<void> {
    this.presence.set(record.accountId, { ...record });
  }

  /** Test/ops helper: raw access to persisted messages. */
  allMessages(): StoredMessage[] {
    return [...this.messages.values()];
  }
}
