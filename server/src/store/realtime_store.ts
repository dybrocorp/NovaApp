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
}

export type RealtimeEventType =
  | 'message.new'
  | 'message.delivered'
  | 'message.read';

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
