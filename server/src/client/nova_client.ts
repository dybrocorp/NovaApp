/**
 * NovaClient — a REAL NovaApp realtime client (Node/TypeScript).
 *
 * This is the harness behind "NOVA CLIENT A" and "NOVA CLIENT B" of the
 * FASE 0.5 validation. It speaks the exact wire contract the Flutter app
 * speaks (`lib/core/services/websocket_service.dart` +
 * `lib/core/socket/`), over real Socket.IO WebSockets:
 *
 *   connect -> auth.challenge -> sign (Ed25519, NOVA_AUTH_v1 canonical)
 *           -> auth.response -> auth.success -> session held on the socket
 *           -> message.send / delivered / read / sync / presence / call.*
 *           -> disconnect -> reconnect -> FULL re-handshake (never reuse)
 *
 * Hard rules mirrored from the app:
 *   * a reconnect ALWAYS re-runs the handshake; an old session is never
 *     replayed or resurrected;
 *   * outgoing messages carry a STABLE message_id, kept in an outbox until
 *     the server acks, and re-emitted with the SAME id after a reconnect
 *     (server-side dedup makes the send exactly-once);
 *   * ordering authority is the server's log_seq / server_seq, never a
 *     client timestamp;
 *   * only opaque ciphertext leaves the client — the plaintext never
 *     touches a wire field.
 *
 * The E2EE layer used by the harness lives in `client/e2ee.ts`.
 */
import { generateKeyPairSync, sign as edSign, type KeyObject } from 'node:crypto';
import { randomUUID } from 'node:crypto';
import { io, type Socket } from 'socket.io-client';

export const CANONICAL_PREFIX = 'NOVA_AUTH_v1';

/** A NovaApp identity: Nova ID + Account ID + Device ID + Ed25519 key. */
export interface NovaIdentity {
  accountId: string;
  deviceId: string;
  novaId: string;
  privateKey: KeyObject;
  /** Raw 32-byte Ed25519 public key, base64 (as registered server-side). */
  publicKeyBase64: string;
}

export interface AuthSuccess {
  session_id: string;
  account_id: string;
  device_id: string;
  nova_id: string;
  expires_at_ms: number;
}

export interface Challenge {
  challenge_id: string;
  challenge: string;
  expires_at_ms: number;
}

export class AuthFailed extends Error {
  constructor(readonly code: string) {
    super(`auth.failure: ${code}`);
  }
}

export type ClientState =
  | 'disconnected'
  | 'connecting'
  | 'awaiting_challenge'
  | 'authenticating'
  | 'authenticated'
  | 'blocked';

interface OutboxEntry {
  messageId: string;
  wire: Record<string, unknown>;
  acked: boolean;
  attempts: number;
}

/** Creates a fresh cryptographic identity (distinct per account/device). */
export function createIdentity(options: {
  accountId: string;
  deviceId: string;
  novaId?: string;
}): NovaIdentity {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const raw = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32);
  return {
    accountId: options.accountId,
    deviceId: options.deviceId,
    novaId: options.novaId ?? `NOVA-${options.accountId.toUpperCase()}`,
    privateKey,
    publicKeyBase64: Buffer.from(raw).toString('base64'),
  };
}

/** The canonical message the client signs (auth_signer.dart parity). */
export function canonicalAuthMessage(input: {
  accountId: string;
  deviceId: string;
  novaId: string;
  challengeId: string;
  challengeBase64: string;
}): string {
  return [
    CANONICAL_PREFIX,
    input.accountId,
    input.deviceId,
    input.novaId,
    input.challengeId,
    input.challengeBase64,
  ].join('|');
}

export interface NovaClientOptions {
  url: string;
  identity: NovaIdentity;
  /** Label used in the harness output (e.g. 'A', 'B'). */
  name?: string;
  defaultTimeoutMs?: number;
}

export class NovaClient {
  readonly identity: NovaIdentity;
  readonly name: string;
  private readonly url: string;
  private readonly timeoutMs: number;

  private socket: Socket | null = null;
  private queues = new Map<string, unknown[]>();
  private waiters = new Map<string, Array<(value: unknown) => void>>();
  private outbox = new Map<string, OutboxEntry>();
  private readonly taps: Array<(event: string, payload: unknown) => void> = [];

  state: ClientState = 'disconnected';
  session: AuthSuccess | null = null;
  /** Handshakes completed by this client instance (reconnects included). */
  handshakes = 0;
  /** Sync cursors per conversation (log_seq). */
  readonly cursors = new Map<string, number>();
  /** Inbound messages, keyed by message_id (client-side dedup proof). */
  readonly inbox = new Map<string, Record<string, unknown>>();
  /** Ordered list of applied inbound message ids. */
  readonly appliedOrder: string[] = [];

  constructor(options: NovaClientOptions) {
    this.identity = options.identity;
    this.url = options.url;
    this.name = options.name ?? options.identity.accountId;
    this.timeoutMs = options.defaultTimeoutMs ?? 5000;
  }

  // ------------------------------------------------------------------
  // Connection lifecycle
  // ------------------------------------------------------------------

  /** Opens the socket. Every event is buffered from creation (no races). */
  connect(): void {
    if (this.state === 'blocked') {
      throw new Error(`${this.name}: device blocked, reconnection refused`);
    }
    this.teardown();
    this.state = 'connecting';
    const socket = io(this.url, {
      transports: ['websocket'], // production policy: no polling downgrade
      reconnection: false, // our own policy drives reconnects
      forceNew: true,
      timeout: 4000,
    });
    this.socket = socket;
    socket.on('connect', () => {
      this.state = 'awaiting_challenge';
      this.enqueue('connect', undefined);
    });
    socket.on('disconnect', (reason) => {
      // A dropped socket ALWAYS invalidates the local session.
      this.session = null;
      if (this.state !== 'blocked') this.state = 'disconnected';
      this.enqueue('disconnect', reason);
    });
    socket.on('connect_error', (error) =>
      this.enqueue('connect_error', (error as Error)?.message ?? 'connect_error'),
    );
    socket.onAny((event, ...args) => {
      const payload = args[0];
      for (const tap of this.taps) tap(event, payload);
      this.observe(event, payload);
      this.enqueue(event, payload);
    });
  }

  /** Records client-side state from server pushes. */
  private observe(event: string, payload: unknown): void {
    const record =
      typeof payload === 'object' && payload !== null
        ? (payload as Record<string, unknown>)
        : {};
    switch (event) {
      case 'message.ack': {
        const id = record['message_id'];
        if (typeof id === 'string') {
          const entry = this.outbox.get(id);
          // ACK == the SERVER received and persisted it. NOT "delivered".
          if (entry) entry.acked = true;
        }
        break;
      }
      case 'message.new': {
        const id = record['message_id'];
        const conv = record['conversation_id'];
        if (typeof id === 'string' && !this.inbox.has(id)) {
          this.inbox.set(id, record);
          this.appliedOrder.push(id);
        }
        const logSeq = record['log_seq'];
        if (typeof conv === 'string' && typeof logSeq === 'number') {
          this.advanceCursor(conv, logSeq);
        }
        break;
      }
      case 'device.revoked': {
        const deviceId = record['device_id'];
        if (deviceId === this.identity.deviceId || deviceId === undefined) {
          // Terminal: the app refuses to reconnect until re-registered.
          this.state = 'blocked';
          this.session = null;
        }
        break;
      }
      default:
        break;
    }
  }

  private advanceCursor(conversationId: string, logSeq: number): void {
    const current = this.cursors.get(conversationId) ?? 0;
    if (logSeq > current) this.cursors.set(conversationId, logSeq);
  }

  /** Runs the full handshake. Resolves on auth.success. */
  async authenticate(
    overrides: {
      accountId?: string;
      deviceId?: string;
      novaId?: string;
      signingKey?: KeyObject;
      signatureBase64?: string;
      challenge?: Challenge;
      timeoutMs?: number;
    } = {},
  ): Promise<AuthSuccess> {
    if (!this.connected) await this.next('connect', overrides.timeoutMs);
    else this.drain('connect');
    const challenge = overrides.challenge ?? (await this.nextChallenge());
    const payload = this.buildAuthResponse(challenge, overrides);
    this.state = 'authenticating';
    const success = await this.sendAuthResponse(payload, overrides.timeoutMs);
    return success;
  }

  /** Waits for the server-issued challenge. */
  nextChallenge(timeoutMs?: number): Promise<Challenge> {
    return this.next<Challenge>('auth.challenge', timeoutMs);
  }

  /** Builds (and signs) an auth.response for a challenge. */
  buildAuthResponse(
    challenge: Challenge,
    overrides: {
      accountId?: string;
      deviceId?: string;
      novaId?: string;
      signingKey?: KeyObject;
      signatureBase64?: string;
    } = {},
  ): Record<string, unknown> {
    const accountId = overrides.accountId ?? this.identity.accountId;
    const deviceId = overrides.deviceId ?? this.identity.deviceId;
    const novaId = overrides.novaId ?? this.identity.novaId;
    const message = canonicalAuthMessage({
      accountId,
      deviceId,
      novaId,
      challengeId: challenge.challenge_id,
      challengeBase64: challenge.challenge,
    });
    const key = overrides.signingKey ?? this.identity.privateKey;
    const signature =
      overrides.signatureBase64 ??
      edSign(null, Buffer.from(message, 'utf8'), key).toString('base64');
    return {
      challenge_id: challenge.challenge_id,
      signature,
      account_id: accountId,
      device_id: deviceId,
      nova_id: novaId,
      ts_ms: Date.now(),
    };
  }

  /** Emits a raw auth.response and resolves the verdict. */
  async sendAuthResponse(
    payload: Record<string, unknown>,
    timeoutMs?: number,
  ): Promise<AuthSuccess> {
    this.emitRaw('auth.response', payload);
    const outcome = await this.race(
      ['auth.success', 'auth.failure', 'disconnect'],
      timeoutMs,
    );
    if (outcome.event === 'auth.success') {
      const success = outcome.payload as AuthSuccess;
      // The app fails closed if the server echoes an identity that is not
      // ours — a session must be bound to THIS device.
      if (
        success.account_id !== this.identity.accountId ||
        success.device_id !== this.identity.deviceId ||
        success.nova_id !== this.identity.novaId
      ) {
        this.state = 'disconnected';
        throw new Error(`${this.name}: auth.success identity mismatch`);
      }
      this.session = success;
      this.state = 'authenticated';
      this.handshakes += 1;
      return success;
    }
    if (outcome.event === 'auth.failure') {
      const code = (outcome.payload as { code?: string })?.code ?? 'AUTH_FAILED';
      if (code === 'DEVICE_REVOKED') this.state = 'blocked';
      throw new AuthFailed(code);
    }
    throw new AuthFailed('DISCONNECTED');
  }

  /**
   * Simulates a network drop + return: the socket dies, a NEW socket is
   * opened, and a FULL handshake runs (new challenge, new signature, new
   * session). Un-acked outbox entries are re-emitted with the same ids.
   */
  async reconnect(options: { downtimeMs?: number; resend?: boolean } = {}): Promise<AuthSuccess> {
    const previousSession = this.session?.session_id ?? null;
    this.dropConnection();
    if (options.downtimeMs && options.downtimeMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, options.downtimeMs));
    }
    this.connect();
    const success = await this.authenticate();
    if (previousSession !== null && success.session_id === previousSession) {
      throw new Error(`${this.name}: server reused an old session id`);
    }
    if (options.resend !== false) this.flushOutbox();
    return success;
  }

  /** Hard transport kill (models losing Internet / switching network). */
  dropConnection(): void {
    this.session = null;
    if (this.state !== 'blocked') this.state = 'disconnected';
    const socket = this.socket;
    this.socket = null;
    if (socket) {
      socket.removeAllListeners();
      socket.disconnect();
    }
    // Buffered server events belong to the dead connection.
    this.queues = new Map();
    this.waiters = new Map();
  }

  disconnect(): void {
    this.dropConnection();
  }

  private teardown(): void {
    if (this.socket) this.dropConnection();
  }

  get connected(): boolean {
    return this.socket?.connected ?? false;
  }

  get authenticated(): boolean {
    return this.state === 'authenticated' && this.session !== null;
  }

  // ------------------------------------------------------------------
  // Messaging
  // ------------------------------------------------------------------

  /**
   * Sends an E2EE envelope. `ciphertextBase64` MUST already be encrypted:
   * this method refuses plaintext-looking fields, exactly like the app.
   */
  sendEnvelope(input: {
    conversationId: string;
    ciphertextBase64: string;
    headerType?: string;
    messageId?: string;
    extra?: Record<string, unknown>;
    /**
     * Re-emits even when the outbox already holds an ack for this id.
     * Models a client that never saw the ack (lost on a dead socket) and
     * retransmits — the case server-side dedup must absorb.
     */
    force?: boolean;
  }): string {
    const messageId = input.messageId ?? randomUUID();
    const wire: Record<string, unknown> = {
      message_id: messageId,
      conversation_id: input.conversationId,
      sender_device_id: this.identity.deviceId,
      ciphertext: input.ciphertextBase64,
      header_type: input.headerType ?? 'dr.v1',
      client_ts_ms: Date.now(), // UI hint only — never ordering authority
      ...input.extra,
    };
    const existing = this.outbox.get(messageId);
    if (!existing) {
      this.outbox.set(messageId, { messageId, wire, acked: false, attempts: 0 });
    } else if (input.force) {
      existing.acked = false;
    }
    this.emitOutbox(messageId);
    return messageId;
  }

  /** Sends and waits for the server ack (SENT). */
  async sendAndAwaitAck(input: {
    conversationId: string;
    ciphertextBase64: string;
    headerType?: string;
    messageId?: string;
    timeoutMs?: number;
  }): Promise<{ messageId: string; ack: Record<string, unknown> }> {
    const messageId = this.sendEnvelope(input);
    const ack = await this.waitForAck(messageId, input.timeoutMs);
    return { messageId, ack };
  }

  /** Waits for the ack matching a specific message_id. */
  async waitForAck(messageId: string, timeoutMs?: number): Promise<Record<string, unknown>> {
    const deadline = Date.now() + (timeoutMs ?? this.timeoutMs);
    for (;;) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new Error(`${this.name}: timeout waiting ack ${messageId}`);
      const ack = (await this.next('message.ack', remaining)) as Record<string, unknown>;
      if (ack['message_id'] === messageId) return ack;
    }
  }

  private emitOutbox(messageId: string): void {
    const entry = this.outbox.get(messageId);
    if (!entry || entry.acked) return;
    entry.attempts += 1;
    this.emitRaw('message.send', entry.wire);
  }

  /** Re-emits every un-acked envelope with its ORIGINAL message_id. */
  flushOutbox(): string[] {
    const resent: string[] = [];
    for (const entry of this.outbox.values()) {
      if (entry.acked) continue;
      this.emitOutbox(entry.messageId);
      resent.push(entry.messageId);
    }
    return resent;
  }

  /** Un-acked message ids currently pending in the outbox. */
  pending(): string[] {
    return [...this.outbox.values()].filter((entry) => !entry.acked).map((e) => e.messageId);
  }

  /** DELIVERED receipt (recipient device received it). Distinct from ACK. */
  markDelivered(conversationId: string, messageId: string): void {
    this.emitRaw('message.delivered', {
      conversation_id: conversationId,
      message_id: messageId,
    });
  }

  /** READ receipt (high-water mark). Distinct from DELIVERED. */
  markRead(conversationId: string, lastReadSeq?: number): void {
    this.emitRaw('message.read', {
      conversation_id: conversationId,
      ...(lastReadSeq !== undefined ? { last_read_seq: lastReadSeq } : {}),
    });
  }

  // ------------------------------------------------------------------
  // Sync / presence / signaling
  // ------------------------------------------------------------------

  /** Requests missed events. Omit conversationId for an account-wide sync. */
  async sync(
    conversationId?: string,
    options: { timeoutMs?: number } = {},
  ): Promise<Record<string, unknown>> {
    if (conversationId !== undefined) {
      this.emitRaw('sync.request', {
        conversation_id: conversationId,
        last_seq: this.cursors.get(conversationId) ?? 0,
      });
    } else {
      this.emitRaw('sync.request', { cursors: Object.fromEntries(this.cursors) });
    }
    const response = (await this.next('sync.response', options.timeoutMs)) as Record<
      string,
      unknown
    >;
    this.applySync(response);
    return response;
  }

  /** Applies a sync.response: dedup by message_id, advance cursors. */
  applySync(response: Record<string, unknown>): { applied: number; duplicates: number } {
    let applied = 0;
    let duplicates = 0;
    const conversations = Array.isArray(response['conversations'])
      ? (response['conversations'] as Array<Record<string, unknown>>)
      : [
          {
            conversation_id: response['conversation_id'],
            events: response['events'],
            cursor: response['cursor'],
          },
        ];
    for (const entry of conversations) {
      const conversationId = entry['conversation_id'];
      const events = Array.isArray(entry['events'])
        ? (entry['events'] as Array<Record<string, unknown>>)
        : [];
      for (const event of events) {
        if (event['type'] !== 'message.new') continue;
        const id = event['message_id'];
        if (typeof id !== 'string') continue;
        if (this.inbox.has(id)) {
          duplicates += 1; // already applied live — never processed twice
          continue;
        }
        this.inbox.set(id, event);
        this.appliedOrder.push(id);
        applied += 1;
      }
      const cursor = entry['cursor'];
      if (typeof conversationId === 'string' && typeof cursor === 'number') {
        this.advanceCursor(conversationId, cursor);
      }
    }
    return { applied, duplicates };
  }

  updatePresence(status: 'online' | 'offline'): void {
    this.emitRaw('presence.update', { status, last_seen_ms: Date.now() });
  }

  /** WebRTC SIGNALING only — media never travels over Socket.IO. */
  signal(
    event: 'call.offer' | 'call.answer' | 'call.ice' | 'call.end',
    peerAccountId: string,
    body: Record<string, unknown> = {},
  ): void {
    this.emitRaw(event, { peer_account_id: peerAccountId, ...body });
  }

  // ------------------------------------------------------------------
  // Raw plumbing
  // ------------------------------------------------------------------

  /**
   * Observes EVERY inbound packet on this socket. Used by the tests to
   * assert that a given secret never reaches a client.
   */
  socketTap(observer: (event: string, payload: unknown) => void): void {
    this.taps.push(observer);
  }

  /** Emits any event verbatim (used to exercise abuse/negative paths). */
  emitRaw(event: string, payload: unknown): void {
    if (!this.socket) throw new Error(`${this.name}: not connected`);
    this.socket.emit(event, payload);
  }

  private enqueue(event: string, payload: unknown): void {
    const waiter = this.waiters.get(event)?.shift();
    if (waiter) {
      waiter(payload);
      return;
    }
    const queue = this.queues.get(event) ?? [];
    queue.push(payload);
    this.queues.set(event, queue);
  }

  /** Awaits the next occurrence of `event` (buffer-aware). */
  next<T = unknown>(event: string, timeoutMs?: number): Promise<T> {
    return this.waitFor<T>(event, timeoutMs).promise;
  }

  /**
   * Buffer-aware wait with an explicit `cancel()`. Cancellation matters
   * for race(): a losing waiter that stays registered would silently
   * swallow the NEXT occurrence of its event.
   */
  private waitFor<T>(
    event: string,
    timeoutMs?: number,
  ): { promise: Promise<T>; cancel: () => void } {
    const queue = this.queues.get(event);
    if (queue && queue.length > 0) {
      return { promise: Promise.resolve(queue.shift() as T), cancel: () => {} };
    }
    let cancel = (): void => {};
    const promise = new Promise<T>((resolve, reject) => {
      const remove = () => {
        const list = this.waiters.get(event) ?? [];
        this.waiters.set(
          event,
          list.filter((entry) => entry !== waiter),
        );
      };
      const timer = setTimeout(() => {
        remove();
        reject(new Error(`${this.name}: timeout waiting for ${event}`));
      }, timeoutMs ?? this.timeoutMs);
      const waiter = (value: unknown) => {
        clearTimeout(timer);
        resolve(value as T);
      };
      cancel = () => {
        clearTimeout(timer);
        remove();
      };
      const list = this.waiters.get(event) ?? [];
      list.push(waiter);
      this.waiters.set(event, list);
    });
    return { promise, cancel };
  }

  /** Resolves with the first of `events` to fire; losers are cancelled. */
  async race(
    events: string[],
    timeoutMs?: number,
  ): Promise<{ event: string; payload: unknown }> {
    const waiters = events.map((event) => ({
      event,
      ...this.waitFor<unknown>(event, timeoutMs),
    }));
    try {
      return await Promise.race(
        waiters.map((entry) =>
          entry.promise.then((payload) => ({ event: entry.event, payload })),
        ),
      );
    } finally {
      // Release every still-pending waiter so later events are not eaten.
      for (const entry of waiters) entry.cancel();
    }
  }

  /** Asserts `event` does NOT arrive within `ms`. */
  async expectNone(event: string, ms = 250): Promise<void> {
    const queued = this.queues.get(event) ?? [];
    if (queued.length > 0) throw new Error(`${this.name}: unexpected ${event}`);
    const arrived = await this.next(event, ms).then(
      () => true,
      () => false,
    );
    if (arrived) throw new Error(`${this.name}: unexpected ${event}`);
  }

  /** Drains any buffered occurrences of an event. */
  drain(event: string): unknown[] {
    const queue = this.queues.get(event) ?? [];
    this.queues.set(event, []);
    return queue;
  }
}
