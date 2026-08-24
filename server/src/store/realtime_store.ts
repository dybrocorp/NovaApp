/**
 * RealtimeStore — hot state owned by the realtime tier:
 * per-conversation sequence cursors, persisted (opaque) message envelopes,
 * the event log that backs sync.response, and presence.
 *
 * The server only ever stores CIPHERTEXT plus server-side metadata
 * (server_seq, received_at) — it MUST NOT be able to decrypt content.
 *
 * Backends: MemoryRealtimeStore (default, single node). Redis-backed
 * variant (INCR cursors, TTL presence, event log stream) is PASO 6 —
 * see docs/SOCKET_SERVER_ARCHITECTURE.md §4.
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

export interface StoredEvent {
  conversationId: string;
  type: RealtimeEventType;
  serverSeq: number;
  atMs: number;
  payload: Record<string, unknown>;
}

export interface PresenceRecord {
  accountId: string;
  status: 'online' | 'offline';
  lastSeenMs: number;
}

export interface RealtimeStore {
  /** INCR cursor:<conversation_id> — monotonic per-conversation sequence. */
  nextSeq(conversationId: string): Promise<number>;
  latestSeq(conversationId: string): Promise<number>;

  persistMessage(message: StoredMessage): Promise<void>;
  findMessage(messageId: string): Promise<StoredMessage | null>;

  /** Appends to the per-conversation event log (backs sync.response). */
  appendEvent(event: StoredEvent): Promise<void>;
  eventsSince(conversationId: string, lastSeq: number, limit: number): Promise<StoredEvent[]>;

  getPresence(accountId: string): Promise<PresenceRecord | null>;
  setPresence(record: PresenceRecord): Promise<void>;
}

export class MemoryRealtimeStore implements RealtimeStore {
  private readonly cursors = new Map<string, number>();
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

  async appendEvent(event: StoredEvent): Promise<void> {
    const log = this.eventLog.get(event.conversationId) ?? [];
    log.push(event);
    this.eventLog.set(event.conversationId, log);
  }

  async eventsSince(conversationId: string, lastSeq: number, limit: number): Promise<StoredEvent[]> {
    const log = this.eventLog.get(conversationId) ?? [];
    return log.filter((event) => event.serverSeq > lastSeq).slice(0, limit);
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
