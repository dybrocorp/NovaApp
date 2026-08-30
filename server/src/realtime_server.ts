/**
 * NovaApp Realtime Server — Socket.IO wiring of the PASO 4 protocol
 * specification. This is the real server (FASE 0.5, PASO 5); every rule
 * here is a port of the audited Dart specifications in
 * `lib/core/socket/` (handshake, challenges, sessions, dedup, rate
 * limits, authorization) — see docs/SOCKET_SERVER_ARCHITECTURE.md.
 *
 * Hard rules enforced here:
 *   1. NO event is accepted before auth.success (system.error FORBIDDEN
 *      + disconnect on violation).
 *   2. Events are authorized against the session bound to the socket —
 *      identity/signatures/tokens are NEVER re-sent per event.
 *   3. Every handshake failure answers the generic AUTH_FAILED (no
 *      enumeration oracle), except RATE_LIMITED / DEVICE_REVOKED where
 *      honest clients must change behavior.
 *   4. The server only ever sees opaque E2EE ciphertext + server-side
 *      metadata (server_seq, received_at).
 *   5. Rooms are granted by server-side truth (membership), never by
 *      client-requested joins.
 */
import { createServer, type Server as HttpServer } from 'node:http';
import { Server as SocketIoServer, type Socket } from 'socket.io';
import type { AddressInfo } from 'node:net';
import { DEFAULT_CONFIG, type RealtimeServerConfig } from './config.js';
import { SocketEvent } from './events.js';
import { SocketErrorCode } from './errors.js';
import {
  TokenBucketRateLimiter,
  createDomainRateLimiters,
  type DomainRateLimiters,
} from './rate_limiter.js';
import { ChallengeStore } from './protocol/challenge_store.js';
import { DeviceRegistry } from './protocol/device_registry.js';
import { SessionRegistry, type RegisteredSession } from './protocol/session_registry.js';
import { MessageDedup } from './protocol/message_dedup.js';
import {
  HandshakeEngine,
  HandshakeOutcome,
  wireFailureCode,
} from './protocol/handshake_engine.js';
import { AuthorizationPolicy, AuthzDecision } from './protocol/authorization_policy.js';
import { MemoryDirectory } from './directory/memory_directory.js';
import type { Directory } from './directory/directory.js';
import {
  MemoryRealtimeStore,
  type RealtimeStore,
  type StoredMessage,
} from './store/realtime_store.js';
import { AuthFailureTracker } from './auth_failure_tracker.js';
import { SecurityLog, type LogSink } from './logger.js';

export interface SocketData {
  session?: RegisteredSession;
  authAttempts: number;
  limiters: DomainRateLimiters;
  ip: string;
}

export interface RealtimeServerOptions {
  config?: Partial<RealtimeServerConfig>;
  directory?: Directory;
  store?: RealtimeStore;
  clock?: () => number;
  /** Redacted log sink (tests capture it to assert no secrets leak). */
  logSink?: LogSink;
}

/** Plaintext-ish keys rejected on the send path (parity with the client). */
export const FORBIDDEN_PLAINTEXT_KEYS: ReadonlySet<string> = new Set([
  'plaintext',
  'plain_text',
  'text',
  'content',
  'body',
  'message',
  'decrypted',
]);

export function containsPlaintextPayload(map: Record<string, unknown>): boolean {
  for (const key of FORBIDDEN_PLAINTEXT_KEYS) {
    const value = map[key];
    if (value !== undefined && value !== null && String(value).length > 0) return true;
  }
  return false;
}

export interface ParsedMessageEnvelope {
  messageId: string;
  conversationId: string;
  senderDeviceId: string;
  ciphertextBase64: string;
  headerType: string;
  clientTimestampMs?: number;
  /**
   * FASE 1 per-device fan-out (§15): when present, this envelope is ONE
   * copy addressed to a specific recipient device, and the server routes
   * it to that device only. Absent = legacy conversation-wide broadcast.
   */
  recipientDeviceId?: string;
  messageType?: string;
  envelopeVersion?: number;
  expiresAtMs?: number;
}

export class RealtimeServer {
  readonly config: RealtimeServerConfig;
  readonly directory: Directory;
  readonly store: RealtimeStore;
  readonly devices = new DeviceRegistry();
  readonly challenges: ChallengeStore;
  readonly sessions: SessionRegistry;
  readonly dedup = new MessageDedup();
  readonly authz: AuthorizationPolicy;
  readonly authFailures: AuthFailureTracker;
  readonly log: SecurityLog;

  private readonly clock: () => number;
  private readonly httpServer: HttpServer;
  private readonly io: SocketIoServer;
  private readonly socketLimiters = new Map<string, DomainRateLimiters>();
  private readonly ipConnections = new Map<string, TokenBucketRateLimiter>();
  private startedAtMs = Date.now();

  private purgeTimer?: ReturnType<typeof setInterval>;

  constructor(options: RealtimeServerOptions = {}) {
    this.config = {
      ...DEFAULT_CONFIG,
      ...(options.config ?? {}),
    };
    this.clock = options.clock ?? Date.now;
    this.directory = options.directory ?? new MemoryDirectory();
    this.store = options.store ?? new MemoryRealtimeStore();
    this.challenges = new ChallengeStore({
      ttlMs: this.config.challengeTtlMs,
      clock: this.clock,
    });
    this.sessions = new SessionRegistry({
      sessionTtlMs: this.config.sessionTtlMs,
      clock: this.clock,
    });
    this.authz = new AuthorizationPolicy(this.directory);
    this.authFailures = new AuthFailureTracker({
      lockoutThreshold: this.config.authFailuresLockout,
      lockoutMs: this.config.authLockoutMs,
      clock: this.clock,
    });
    this.log = new SecurityLog({ sink: options.logSink });

    // FASE 1 §22: elapsed expirations are PURGED server-side regardless of
    // client liveness. unref(): the sweep must never keep the process alive.
    this.purgeTimer = setInterval(() => {
      void this.purgeExpired();
    }, this.config.messagePurgeIntervalMs);
    this.purgeTimer.unref?.();

    this.httpServer = createServer();
    this.io = new SocketIoServer(this.httpServer, {
      path: this.config.socketPath,
      // WebSocket-only (no polling downgrade in production) — parity with
      // the audited client transport policy. No sticky sessions required.
      transports: ['websocket'],
      pingInterval: this.config.pingIntervalMs,
      pingTimeout: this.config.pingTimeoutMs,
      maxHttpBufferSize: this.config.maxHttpBufferSize,
      perMessageDeflate: false,
      cors: {
        origin: this.config.corsOrigins,
        methods: ['GET', 'POST'],
      },
      connectionStateRecovery: {
        // Server-side recovery is OFF: a reconnect MUST re-run the full
        // cryptographic handshake (client rule, PASO 4). Sessions are
        // never resurrected from a recovered connection.
        maxDisconnectionDuration: 0,
      },
    });

    this.io.use(this.connectionMiddleware.bind(this));
    this.io.on('connection', this.onConnection.bind(this));
  }

  // ------------------------------------------------------------------
  // Lifecycle
  // ------------------------------------------------------------------

  /** Starts listening. Port 0 = ephemeral (tests). Returns the bound port. */
  start(options: { port?: number; host?: string } = {}): Promise<number> {
    return new Promise((resolve) => {
      this.httpServer.listen(options.port ?? 0, options.host ?? '0.0.0.0', () => {
        const address = this.httpServer.address() as AddressInfo;
        resolve(address.port);
      });
    });
  }

  /** Graceful shutdown: broadcast system.shutdown, then close. */
  async stop(): Promise<void> {
    if (this.purgeTimer) clearInterval(this.purgeTimer);
    this.io.emit(SocketEvent.systemShutdown, { reason: 'server_shutdown' });
    await new Promise((resolve) => setTimeout(resolve, 30));
    await new Promise<void>((resolve) => {
      this.io.close(() => resolve());
    });
    await new Promise<void>((resolve) => {
      this.httpServer.close(() => resolve());
      this.httpServer.closeAllConnections();
    });
  }

  get port(): number {
    return (this.httpServer.address() as AddressInfo).port;
  }

  get uptimeSeconds(): number {
    return Math.round((Date.now() - this.startedAtMs) / 1000);
  }

  get connectedSockets(): number {
    return this.io.of('/').sockets.size;
  }

  get httpServerInstance(): HttpServer {
    return this.httpServer;
  }

  // ------------------------------------------------------------------
  // Connection + handshake
  // ------------------------------------------------------------------

  /** Per-IP new-connection limit (token bucket, docs §7). */
  private connectionMiddleware(socket: Socket, next: (err?: Error) => void): void {
    const ip = this.clientIp(socket);
    let bucket = this.ipConnections.get(ip);
    if (!bucket) {
      bucket = new TokenBucketRateLimiter({
        burst: this.config.newConnectionsPerIpPerMinute,
        perMinute: this.config.newConnectionsPerIpPerMinute,
        clock: this.clock,
      });
      this.ipConnections.set(ip, bucket);
    }
    if (!bucket.allow()) {
      next(new Error('RATE_LIMITED'));
      return;
    }
    next();
  }

  private clientIp(socket: Socket): string {
    return socket.handshake.headers['x-forwarded-for']?.toString().split(',')[0]?.trim()
      ?? socket.handshake.address
      ?? 'unknown';
  }

  private onConnection(socket: Socket): void {
    const data = socket.data as SocketData;
    data.authAttempts = 0;
    data.ip = this.clientIp(socket);
    data.limiters = createDomainRateLimiters(this.config, this.clock);
    this.socketLimiters.set(socket.id, data.limiters);

    // Challenge issued immediately on connection (client contract): bound
    // to THIS socket only; re-bound to the claimed identity on
    // auth.response (documented variant — see ChallengeStore).
    const issued = this.challenges.issue(socket.id);
    socket.emit(SocketEvent.authChallenge, {
      challenge_id: issued.challengeId,
      challenge: issued.challengeBase64,
      expires_at_ms: issued.expiresAtMs,
    });

    socket.on(SocketEvent.authResponse, (payload: unknown) => {
      void this.onAuthResponse(socket, payload);
    });
    socket.on(SocketEvent.messageSend, (payload: unknown) => {
      void this.onMessageSend(socket, payload);
    });
    socket.on(SocketEvent.messageTyping, (payload: unknown) => {
      void this.onMessageTyping(socket, payload);
    });
    socket.on(SocketEvent.messageDelivered, (payload: unknown) => {
      void this.onMessageDelivered(socket, payload);
    });
    socket.on(SocketEvent.messageDelete, (payload: unknown) => {
      void this.onMessageDelete(socket, payload);
    });
    socket.on(SocketEvent.messageRead, (payload: unknown) => {
      void this.onMessageRead(socket, payload);
    });
    socket.on(SocketEvent.syncRequest, (payload: unknown) => {
      void this.onSyncRequest(socket, payload);
    });
    socket.on(SocketEvent.presenceUpdate, (payload: unknown) => {
      void this.onPresenceUpdate(socket, payload);
    });
    socket.on(SocketEvent.callOffer, (payload: unknown) => {
      void this.onCallSignal(socket, SocketEvent.callOffer, payload);
    });
    socket.on(SocketEvent.callAnswer, (payload: unknown) => {
      void this.onCallSignal(socket, SocketEvent.callAnswer, payload);
    });
    socket.on(SocketEvent.callIce, (payload: unknown) => {
      void this.onCallSignal(socket, SocketEvent.callIce, payload);
    });
    socket.on(SocketEvent.callEnd, (payload: unknown) => {
      void this.onCallSignal(socket, SocketEvent.callEnd, payload);
    });

    socket.on('disconnect', (reason: string) => {
      this.socketLimiters.delete(socket.id);
      void this.onDisconnect(socket, reason);
    });
  }

  /**
   * Disconnect cleanup: drop the session bound to this socket and, when
   * the account has no other live socket, publish presence OFFLINE with a
   * last_seen timestamp to the privacy audience (FASE 0.5 §14).
   */
  private async onDisconnect(socket: Socket, reason: string): Promise<void> {
    const data = socket.data as SocketData;
    const session = data.session;
    this.log.event('socket.disconnect', {
      reason,
      account_id: session?.accountId,
      device_id: session?.deviceId,
    });
    if (!session) return;
    data.session = undefined;
    // Only drop the registry entry if it still points at THIS socket: a
    // reconnect of the same device may already own a newer session.
    const current = this.sessions.bySessionId(session.sessionId);
    if (current !== null && current.socketKey === socket.id) {
      this.sessions.revoke(session.sessionId);
    }
    if (this.accountHasLiveSocket(session.accountId)) return;
    const lastSeenMs = this.clock();
    await this.store.setPresence({
      accountId: session.accountId,
      status: 'offline',
      lastSeenMs,
    });
    const audience = await this.directory.presenceAudience(session.accountId);
    for (const viewerAccountId of audience) {
      this.io.to(`account:${viewerAccountId}`).emit(SocketEvent.presenceChanged, {
        account_id: session.accountId,
        status: 'offline',
        last_seen_ms: lastSeenMs,
      });
    }
  }

  /** True when any still-connected socket carries a session of this account. */
  private accountHasLiveSocket(accountId: string): boolean {
    for (const socket of this.io.of('/').sockets.values()) {
      const other = socket.data as SocketData;
      if (socket.connected && other.session?.accountId === accountId) return true;
    }
    return false;
  }

  private async onAuthResponse(socket: Socket, payload: unknown): Promise<void> {
    const data = socket.data as SocketData;
    data.authAttempts += 1;

    // Defense in depth: at most maxAuthAttemptsPerConnection auth.response
    // per socket (normally unreachable: any failure disconnects).
    if (data.authAttempts > this.config.maxAuthAttemptsPerConnection) {
      socket.emit(SocketEvent.authFailure, { code: SocketErrorCode.rateLimited });
      this.disconnectSocket(socket);
      return;
    }

    if (!data.limiters.auth.allow() || !data.limiters.aggregate.allow()) {
      socket.emit(SocketEvent.authFailure, { code: SocketErrorCode.rateLimited });
      this.disconnectSocket(socket);
      return;
    }

    // Lockout check BEFORE any challenge is consumed: locked identities
    // cannot burn challenges (docs §2).
    const record = this.payloadObject(payload);
    const lockoutKeys = this.lockoutScopeKeys(data, record);
    if (lockoutKeys.some((key) => this.authFailures.isLocked(key))) {
      socket.emit(SocketEvent.authFailure, { code: SocketErrorCode.rateLimited });
      this.disconnectSocket(socket);
      return;
    }

    const engine = new HandshakeEngine(this.devices, this.challenges, this.sessions);
    const result = await engine.handleAuthResponse({
      socketKey: socket.id,
      payload: record,
      rebindWildcardChallenge: true,
    });

    if (result.outcome !== HandshakeOutcome.success || !result.session) {
      for (const key of lockoutKeys) this.authFailures.recordFailure(key);
      // Logged: the internal outcome name only. It carries NO key, NO
      // signature, NO challenge bytes — just which check failed.
      this.log.event('auth.failure', {
        outcome: result.outcome,
        device_id: typeof record['device_id'] === 'string' ? record['device_id'] : undefined,
        ip: data.ip,
      });
      // Generic code on the wire — no enumeration oracle (docs §2).
      socket.emit(SocketEvent.authFailure, { code: wireFailureCode(result.outcome) });
      this.disconnectSocket(socket);
      return;
    }

    // Success: a legitimate device resets its own device-scope counters.
    for (const key of lockoutKeys) {
      if (key.startsWith('device:')) this.authFailures.clear(key);
    }

    // One live session per device: disconnect the sockets of evicted
    // sessions (the device reconnected elsewhere).
    for (const evicted of result.evicted) {
      this.disconnectSocketKey(evicted.socketKey, SocketErrorCode.sessionExpired);
    }

    data.session = result.session;

    // Rooms granted by server-side truth only.
    await socket.join(`account:${result.session.accountId}`);
    await socket.join(`device:${result.session.deviceId}`);
    const conversations = await this.directory.listConversationsForAccount(
      result.session.accountId,
    );
    for (const conversationId of conversations) {
      await socket.join(`conv:${conversationId}`);
    }

    this.log.event('auth.success', {
      account_id: result.session.accountId,
      device_id: result.session.deviceId,
      evicted: result.evicted.length,
    });

    socket.emit(SocketEvent.authSuccess, {
      session_id: result.session.sessionId,
      account_id: result.session.accountId,
      device_id: result.session.deviceId,
      nova_id: result.session.novaId,
      expires_at_ms: result.session.expiresAtMs,
    });
  }

  private lockoutScopeKeys(
    data: SocketData,
    payload: Record<string, unknown>,
  ): string[] {
    const keys: string[] = [];
    for (const scope of this.config.authLockoutScopes) {
      if (scope === 'device' && typeof payload['device_id'] === 'string') {
        keys.push(`device:${payload['device_id']}`);
      } else if (scope === 'ip') {
        keys.push(`ip:${data.ip}`);
      }
    }
    return keys;
  }

  // ------------------------------------------------------------------
  // Session guard (applies to every post-auth event)
  // ------------------------------------------------------------------

  private requireSession(socket: Socket, event: string): RegisteredSession | null {
    const data = socket.data as SocketData;
    if (!data.session) {
      // No authenticated session on this socket: protocol violation.
      socket.emit(SocketEvent.systemError, { code: SocketErrorCode.forbidden, event });
      socket.data.limiters?.aggregate.drain();
      this.disconnectSocket(socket);
      return null;
    }
    const validation = this.sessions.validate(data.session.sessionId, socket.id);
    if (validation !== 'ok') {
      socket.emit(SocketEvent.systemError, { code: SocketErrorCode.sessionExpired, event });
      this.disconnectSocket(socket);
      return null;
    }
    return data.session;
  }

  private consumeRate(
    data: SocketData,
    domain: 'message' | 'typing' | 'signaling' | 'sync' | 'presence',
  ): boolean {
    return data.limiters[domain].allow() && data.limiters.aggregate.allow();
  }

  // ------------------------------------------------------------------
  // Messaging
  // ------------------------------------------------------------------

  private parseMessageEnvelope(
    payload: unknown,
    session: RegisteredSession,
  ): { envelope?: ParsedMessageEnvelope; error?: string } {
    if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) {
      return { error: SocketErrorCode.payloadInvalid };
    }
    const record = payload as Record<string, unknown>;
    if (containsPlaintextPayload(record)) {
      return { error: SocketErrorCode.payloadInvalid };
    }
    const messageId = record['message_id'];
    const conversationId = record['conversation_id'];
    const ciphertext = record['ciphertext'];
    const headerType = record['header_type'];
    if (
      typeof messageId !== 'string' || messageId.length === 0 ||
      typeof conversationId !== 'string' || conversationId.length === 0 ||
      typeof ciphertext !== 'string' || ciphertext.length === 0 ||
      typeof headerType !== 'string' || headerType.length === 0
    ) {
      return { error: SocketErrorCode.payloadInvalid };
    }
    if (ciphertext.length > this.config.maxCiphertextBase64Chars) {
      return { error: SocketErrorCode.payloadInvalid };
    }
    const senderDeviceId = record['sender_device_id'];
    if (senderDeviceId !== undefined && senderDeviceId !== session.deviceId) {
      // Spoofing another device id of the (possibly same) account: reject.
      return { error: SocketErrorCode.payloadInvalid };
    }
    const clientTs = record['client_ts_ms'];
    if (clientTs !== undefined && typeof clientTs !== 'number') {
      return { error: SocketErrorCode.payloadInvalid };
    }

    // FASE 1 (§15): optional per-device addressing.
    const recipientDeviceId = record['recipient_device_id'];
    if (
      recipientDeviceId !== undefined &&
      (typeof recipientDeviceId !== 'string' || recipientDeviceId.length === 0)
    ) {
      return { error: SocketErrorCode.payloadInvalid };
    }
    const messageType = record['message_type'];
    if (messageType !== undefined && typeof messageType !== 'string') {
      return { error: SocketErrorCode.payloadInvalid };
    }
    const envelopeVersion = record['envelope_version'];
    if (envelopeVersion !== undefined && typeof envelopeVersion !== 'number') {
      return { error: SocketErrorCode.payloadInvalid };
    }
    const expiresAt = record['expires_at_ms'];
    if (expiresAt !== undefined && typeof expiresAt !== 'number') {
      return { error: SocketErrorCode.payloadInvalid };
    }

    return {
      envelope: {
        messageId,
        conversationId,
        senderDeviceId: session.deviceId,
        ciphertextBase64: ciphertext,
        headerType,
        clientTimestampMs: typeof clientTs === 'number' ? clientTs : undefined,
        recipientDeviceId:
          typeof recipientDeviceId === 'string' ? recipientDeviceId : undefined,
        messageType: typeof messageType === 'string' ? messageType : undefined,
        envelopeVersion:
          typeof envelopeVersion === 'number' ? envelopeVersion : undefined,
        expiresAtMs: typeof expiresAt === 'number' ? expiresAt : undefined,
      },
    };
  }

  private async onMessageSend(socket: Socket, payload: unknown): Promise<void> {
    const data = socket.data as SocketData;
    const session = this.requireSession(socket, SocketEvent.messageSend);
    if (!session) return;

    const messageId =
      typeof (payload as Record<string, unknown> | null | undefined)?.['message_id'] === 'string'
        ? (payload as Record<string, unknown>)['message_id']
        : undefined;

    if (!this.consumeRate(data, 'message')) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.rateLimited,
        event: SocketEvent.messageSend,
        message_id: messageId,
      });
      return;
    }

    const parsed = this.parseMessageEnvelope(payload, session);
    if (!parsed.envelope) {
      socket.emit(SocketEvent.systemError, {
        code: parsed.error,
        event: SocketEvent.messageSend,
        message_id: messageId,
      });
      return;
    }
    const envelope = parsed.envelope;

    const decision = await this.authz.canSendMessage(session, envelope.conversationId);
    if (decision !== AuthzDecision.allow) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.forbidden,
        event: SocketEvent.messageSend,
        message_id: envelope.messageId,
      });
      return;
    }

    // Idempotency: a retried message_id gets the ORIGINAL ack (same
    // server_seq) and is NOT re-persisted / re-fanned-out.
    //
    // The dedup key is scoped to the SENDING ACCOUNT: message_id is chosen
    // by the client, so a global namespace would let an attacker
    // pre-register ids and silently swallow another account's messages
    // (a denial-of-delivery oracle). Scoping makes the id collision-safe.
    //
    // FASE 1 (§15): with per-device fan-out the SAME message_id is sent
    // once per recipient device. Those copies are DIFFERENT ciphertexts
    // and must all be delivered, so the dedup key includes the recipient
    // device. Without it, only the first device would ever receive the
    // message and the rest would be silently swallowed as "duplicates".
    const storageKey = envelope.recipientDeviceId
      ? `${envelope.messageId}#${envelope.recipientDeviceId}`
      : envelope.messageId;
    const dedupKey = `${session.accountId}|${storageKey}`;
    if (!this.dedup.accept(dedupKey)) {
      const original = await this.store.findMessage(storageKey);
      // Only replay the original ack when the stored message really is
      // this sender's, in this conversation.
      const sameOrigin =
        original !== null &&
        original.senderAccountId === session.accountId &&
        original.conversationId === envelope.conversationId;
      this.log.event('message.duplicate', {
        account_id: session.accountId,
        conversation_id: envelope.conversationId,
        message_id: envelope.messageId,
        resolved: sameOrigin,
      });
      socket.emit(SocketEvent.messageAck, {
        message_id: envelope.messageId,
        conversation_id: envelope.conversationId,
        server_seq: sameOrigin ? original.serverSeq : 0,
        duplicate: true,
        ...(envelope.recipientDeviceId !== undefined
          ? { recipient_device_id: envelope.recipientDeviceId }
          : {}),
      });
      return;
    }

    const serverSeq = await this.store.nextSeq(envelope.conversationId);
    const receivedAtMs = this.clock();
    const stored: StoredMessage = {
      // Storage key includes the target device so per-device copies do
      // not overwrite each other; the wire keeps the logical message_id.
      messageId: storageKey,
      conversationId: envelope.conversationId,
      senderAccountId: session.accountId,
      senderDeviceId: envelope.senderDeviceId,
      ciphertextBase64: envelope.ciphertextBase64,
      headerType: envelope.headerType,
      serverSeq,
      receivedAtMs,
      clientTimestampMs: envelope.clientTimestampMs,
      expiresAtMs: envelope.expiresAtMs,
    };
    await this.store.persistMessage(stored);

    // The log payload is the EXACT wire shape of the live fan-out packet,
    // so a message recovered through sync.response is byte-identical to
    // one received live (a client must not need two parsers).
    const wire = {
      message_id: envelope.messageId,
      conversation_id: envelope.conversationId,
      sender_account_id: session.accountId,
      sender_device_id: envelope.senderDeviceId,
      ciphertext: envelope.ciphertextBase64,
      header_type: envelope.headerType,
      server_seq: serverSeq,
      received_at_ms: receivedAtMs,
      ...(envelope.recipientDeviceId !== undefined
        ? { recipient_device_id: envelope.recipientDeviceId }
        : {}),
      ...(envelope.messageType !== undefined
        ? { message_type: envelope.messageType }
        : {}),
      ...(envelope.envelopeVersion !== undefined
        ? { envelope_version: envelope.envelopeVersion }
        : {}),
      ...(envelope.expiresAtMs !== undefined
        ? { expires_at_ms: envelope.expiresAtMs }
        : {}),
      ...(envelope.clientTimestampMs !== undefined
        ? { client_ts_ms: envelope.clientTimestampMs }
        : {}),
    };
    const logSeq = await this.store.appendEvent({
      conversationId: envelope.conversationId,
      type: 'message.new',
      serverSeq,
      atMs: receivedAtMs,
      payload: wire,
    });

    // Membership-granted room (lazy ensure in case membership was added
    // after this socket authenticated).
    await socket.join(`conv:${envelope.conversationId}`);

    this.log.event('message.accepted', {
      account_id: session.accountId,
      device_id: session.deviceId,
      conversation_id: envelope.conversationId,
      message_id: envelope.messageId,
      server_seq: serverSeq,
      log_seq: logSeq,
      bytes: envelope.ciphertextBase64.length,
    });

    // 1) ack to the emitter: RECEIVED + persisted (not delivered/read).
    socket.emit(SocketEvent.messageAck, {
      message_id: envelope.messageId,
      conversation_id: envelope.conversationId,
      server_seq: serverSeq,
      log_seq: logSeq,
      // Echoed so the sender can match the ack to the right per-device
      // Outbox row: one message_id has one ack PER recipient device.
      ...(envelope.recipientDeviceId !== undefined
        ? { recipient_device_id: envelope.recipientDeviceId }
        : {}),
    });

    // 2) fan-out to the conversation room (sender's OTHER devices receive
    //    it too; the emitting socket only gets the ack). Identical shape
    //    to the logged payload replayed by sync.response.
    if (envelope.recipientDeviceId !== undefined) {
      // Per-device copy (§15): deliver ONLY to the addressed device.
      // Broadcasting it to the whole conversation would hand every
      // member a ciphertext they cannot decrypt, and would leak the
      // device fan-out pattern to the other participants.
      this.io
        .to(`device:${envelope.recipientDeviceId}`)
        .except(socket.id)
        .emit(SocketEvent.messageNew, { ...wire, log_seq: logSeq });
    } else {
      // Legacy conversation-wide broadcast (FASE 0.5 contract).
      this.io
        .to(`conv:${envelope.conversationId}`)
        .except(socket.id)
        .emit(SocketEvent.messageNew, { ...wire, log_seq: logSeq });
    }
  }

  /**
   * FASE 1 §21: delete-for-everyone — SERVER side half.
   *
   * Authorization: only the SENDER ACCOUNT may redact, addressed by the
   * LOGICAL message id (every per-device copy of that sender is redacted at
   * once). Redaction destroys the stored ciphertext and rewrites the event
   * log entry so sync replay yields a tombstone — a device that syncs later
   * can never fetch content deleted before it connected. The recipient-side
   * erase of DECRYPTED copies travels as an encrypted control message
   * through the normal send path (the server never sees its meaning).
   */
  private async onMessageDelete(socket: Socket, payload: unknown): Promise<void> {
    const data = socket.data as SocketData;
    const session = this.requireSession(socket, SocketEvent.messageDelete);
    if (!session) return;
    if (!this.consumeRate(data, 'message')) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.rateLimited,
        event: SocketEvent.messageDelete,
      });
      return;
    }
    const record = this.payloadObject(payload);
    const conversationId = record['conversation_id'];
    const messageId = record['message_id'];
    if (
      typeof conversationId !== 'string' ||
      conversationId.length === 0 ||
      typeof messageId !== 'string' ||
      messageId.length === 0
    ) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.payloadInvalid,
        event: SocketEvent.messageDelete,
      });
      return;
    }
    const atMs = this.clock();
    const outcome = await this.store.redactMessages(
      conversationId,
      messageId,
      session.accountId,
      'deleted',
      atMs,
    );
    if (outcome.redacted === 0) {
      // Unknown, foreign, or already redacted: one generic rejection —
      // existence is never leaked to non-owners.
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.forbidden,
        event: SocketEvent.messageDelete,
        ...(outcome.already === true ? { already_tombstoned: true } : {}),
      });
      return;
    }
    const tombstone = {
      conversation_id: conversationId,
      message_id: messageId,
      by_account_id: session.accountId,
      at_ms: atMs,
      ...(outcome.tombstoneServerSeq !== undefined
        ? { server_seq: outcome.tombstoneServerSeq }
        : {}),
      ...(outcome.tombstoneLogSeq !== undefined
        ? { log_seq: outcome.tombstoneLogSeq }
        : {}),
    };
    // The whole room INCLUDING the requesting device (its own local copy
    // must erase too); ids + flags only.
    this.io
      .to(`conv:${conversationId}`)
      .emit(SocketEvent.messageDeleted, tombstone);
    this.log.event('message.tombstoned', {
      account_id: session.accountId,
      device_id: session.deviceId,
      conversation_id: conversationId,
      message_id: messageId,
      copies: outcome.redacted,
    });
  }

  /** FASE 1 §22: periodic expiry sweep — purge ciphertext and notify. */
  private async purgeExpired(): Promise<void> {
    const hits = await this.store.purgeExpiredMessages(this.clock());
    for (const hit of hits) {
      this.io.to(`conv:${hit.conversationId}`).emit(SocketEvent.messageExpired, {
        conversation_id: hit.conversationId,
        message_id: hit.messageId,
        at_ms: this.clock(),
        log_seq: hit.logSeq,
      });
    }
    if (hits.length > 0) {
      this.log.event('message.expired_purge', { purged: hits.length });
    }
  }

  private async onMessageTyping(socket: Socket, payload: unknown): Promise<void> {
    const data = socket.data as SocketData;
    const session = this.requireSession(socket, SocketEvent.messageTyping);
    if (!session) return;
    if (!this.consumeRate(data, 'typing')) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.rateLimited,
        event: SocketEvent.messageTyping,
      });
      return;
    }
    const conversationId = (payload as Record<string, unknown> | null)?.['conversation_id'];
    if (typeof conversationId !== 'string' || conversationId.length === 0) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.payloadInvalid,
        event: SocketEvent.messageTyping,
      });
      return;
    }
    const decision = await this.authz.canReadConversation(session, conversationId);
    if (decision !== AuthzDecision.allow) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.forbidden,
        event: SocketEvent.messageTyping,
      });
      return;
    }
    await socket.join(`conv:${conversationId}`);
    this.io
      .to(`conv:${conversationId}`)
      .except(socket.id)
      .emit(SocketEvent.messageTyping, {
        conversation_id: conversationId,
        account_id: session.accountId,
        device_id: session.deviceId,
      });
  }

  private async onMessageDelivered(socket: Socket, payload: unknown): Promise<void> {
    const data = socket.data as SocketData;
    const session = this.requireSession(socket, SocketEvent.messageDelivered);
    if (!session) return;
    if (!this.consumeRate(data, 'message')) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.rateLimited,
        event: SocketEvent.messageDelivered,
      });
      return;
    }
    const record = this.payloadObject(payload);
    const conversationId = record['conversation_id'];
    const messageId = record['message_id'];
    if (typeof conversationId !== 'string' || typeof messageId !== 'string') {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.payloadInvalid,
        event: SocketEvent.messageDelivered,
      });
      return;
    }
    const decision = await this.authz.canReadConversation(session, conversationId);
    if (decision !== AuthzDecision.allow) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.forbidden,
        event: SocketEvent.messageDelivered,
      });
      return;
    }
    const original = await this.store.findMessage(messageId);
    // A receipt for a message that does not exist in this conversation is
    // rejected: receipts must never be able to invent log entries.
    if (original === null || original.conversationId !== conversationId) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.payloadInvalid,
        event: SocketEvent.messageDelivered,
      });
      return;
    }
    // A device never "delivers" its own outgoing message.
    if (original.senderAccountId === session.accountId) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.payloadInvalid,
        event: SocketEvent.messageDelivered,
      });
      return;
    }
    const atMs = this.clock();
    const serverSeq = original.serverSeq;
    // DELIVERED is a distinct state from SENT (message.ack) and from READ.
    const receipt = {
      conversation_id: conversationId,
      message_id: messageId,
      by_account_id: session.accountId,
      by_device_id: session.deviceId,
      server_seq: serverSeq,
      at_ms: atMs,
    };
    const logSeq = await this.store.appendEvent({
      conversationId,
      type: 'message.delivered',
      serverSeq,
      atMs,
      payload: receipt,
    });
    this.io
      .to(`conv:${conversationId}`)
      .except(socket.id)
      .emit(SocketEvent.messageDelivered, { ...receipt, log_seq: logSeq });
  }

  private async onMessageRead(socket: Socket, payload: unknown): Promise<void> {
    const data = socket.data as SocketData;
    const session = this.requireSession(socket, SocketEvent.messageRead);
    if (!session) return;
    if (!this.consumeRate(data, 'message')) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.rateLimited,
        event: SocketEvent.messageRead,
      });
      return;
    }
    const record = this.payloadObject(payload);
    const conversationId = record['conversation_id'];
    if (typeof conversationId !== 'string' || conversationId.length === 0) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.payloadInvalid,
        event: SocketEvent.messageRead,
      });
      return;
    }
    const decision = await this.authz.canReadConversation(session, conversationId);
    if (decision !== AuthzDecision.allow) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.forbidden,
        event: SocketEvent.messageRead,
      });
      return;
    }
    // READ is a high-water mark: "everything up to last_read_seq".
    // A client-supplied value is CLAMPED to what actually exists, so a
    // client can never move the mark past the server's own sequence.
    const lastReadSeqRaw = record['last_read_seq'];
    const atMs = this.clock();
    const latest = await this.store.latestSeq(conversationId);
    const requested =
      typeof lastReadSeqRaw === 'number' && Number.isFinite(lastReadSeqRaw)
        ? Math.floor(lastReadSeqRaw)
        : latest;
    const serverSeq = Math.max(0, Math.min(requested, latest));
    const receipt = {
      conversation_id: conversationId,
      by_account_id: session.accountId,
      by_device_id: session.deviceId,
      last_read_seq: serverSeq,
      at_ms: atMs,
    };
    const logSeq = await this.store.appendEvent({
      conversationId,
      type: 'message.read',
      serverSeq,
      atMs,
      payload: receipt,
    });
    this.io
      .to(`conv:${conversationId}`)
      .except(socket.id)
      .emit(SocketEvent.messageRead, { ...receipt, log_seq: logSeq });
  }

  // ------------------------------------------------------------------
  // Sync
  // ------------------------------------------------------------------

  private async onSyncRequest(socket: Socket, payload: unknown): Promise<void> {
    const data = socket.data as SocketData;
    const session = this.requireSession(socket, SocketEvent.syncRequest);
    if (!session) return;
    if (!this.consumeRate(data, 'sync')) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.rateLimited,
        event: SocketEvent.syncRequest,
      });
      return;
    }
    const record = this.payloadObject(payload);
    const conversationId = record['conversation_id'];

    // Two shapes are accepted (FASE 0.5 §15):
    //   { conversation_id, last_seq }  -> one conversation
    //   { cursors: { <conv>: <last_seq> } } or {} -> EVERY conversation the
    //   account belongs to. After a reconnect a client does not yet know
    //   which conversations changed while it was offline, so a
    //   conversation-only sync could never recover a message that arrived
    //   in a chat it had not opened.
    if (conversationId !== undefined && typeof conversationId !== 'string') {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.payloadInvalid,
        event: SocketEvent.syncRequest,
      });
      return;
    }

    // Cursor field: `last_seq` is the LOG cursor (see RealtimeStore docs).
    const readCursor = (raw: unknown): number =>
      typeof raw === 'number' && Number.isFinite(raw) && raw > 0 ? Math.floor(raw) : 0;

    let targets: string[];
    const cursors = new Map<string, number>();
    if (typeof conversationId === 'string' && conversationId.length > 0) {
      const decision = await this.authz.canReadConversation(session, conversationId);
      if (decision !== AuthzDecision.allow) {
        socket.emit(SocketEvent.systemError, {
          code: SocketErrorCode.forbidden,
          event: SocketEvent.syncRequest,
        });
        return;
      }
      targets = [conversationId];
      cursors.set(conversationId, readCursor(record['last_seq']));
    } else {
      // Account-wide: membership is server-side truth, so every returned
      // conversation is authorized by construction.
      targets = await this.directory.listConversationsForAccount(session.accountId);
      const supplied = this.payloadObject(record['cursors']);
      for (const target of targets) {
        cursors.set(target, readCursor(supplied[target]));
      }
    }

    const conversations: Array<Record<string, unknown>> = [];
    let hasMore = false;
    for (const target of targets) {
      const events = await this.store.eventsSince(
        target,
        cursors.get(target) ?? 0,
        this.config.syncPageLimit,
      );
      const latestLogSeq = await this.store.latestLogSeq(target);
      const pageIsFull = events.length === this.config.syncPageLimit;
      if (pageIsFull) hasMore = true;
      // Cursor = last event actually delivered in THIS page. Advancing it
      // to the head while truncating a page would skip events forever.
      const cursor = pageIsFull
        ? events[events.length - 1]!.logSeq
        : latestLogSeq;
      await socket.join(`conv:${target}`);
      conversations.push({
        conversation_id: target,
        events: events.map((event) => ({
          type: event.type,
          log_seq: event.logSeq,
          server_seq: event.serverSeq,
          at_ms: event.atMs,
          ...event.payload,
        })),
        cursor,
        has_more: pageIsFull,
      });
    }

    this.log.event('sync.served', {
      account_id: session.accountId,
      device_id: session.deviceId,
      conversations: conversations.length,
      events: conversations.reduce(
        (total, entry) => total + (entry['events'] as unknown[]).length,
        0,
      ),
    });

    const single = conversations.length === 1 ? conversations[0]! : null;
    socket.emit(SocketEvent.syncResponse, {
      // Multi-conversation view (always present).
      conversations,
      has_more: hasMore,
      // Back-compatible single-conversation view: kept so the existing
      // client contract (conversation_id/events/cursor at top level)
      // keeps working unchanged.
      ...(single !== null
        ? {
            conversation_id: single['conversation_id'],
            events: single['events'],
            cursor: single['cursor'],
          }
        : { events: [], cursor: 0 }),
    });
  }

  // ------------------------------------------------------------------
  // Presence
  // ------------------------------------------------------------------

  private async onPresenceUpdate(socket: Socket, payload: unknown): Promise<void> {
    const data = socket.data as SocketData;
    const session = this.requireSession(socket, SocketEvent.presenceUpdate);
    if (!session) return;
    if (!this.consumeRate(data, 'presence')) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.rateLimited,
        event: SocketEvent.presenceUpdate,
      });
      return;
    }
    const record = this.payloadObject(payload);
    const status = record['status'];
    if (status !== 'online' && status !== 'offline') {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.payloadInvalid,
        event: SocketEvent.presenceUpdate,
      });
      return;
    }
    const lastSeenRaw = record['last_seen_ms'];
    const lastSeenMs =
      typeof lastSeenRaw === 'number' && lastSeenRaw > 0 ? lastSeenRaw : this.clock();
    await this.store.setPresence({
      accountId: session.accountId,
      status,
      lastSeenMs,
    });
    this.log.event('presence.update', {
      account_id: session.accountId,
      status,
    });
    // Fan out ONLY to the subject's privacy audience — never global.
    const audience = await this.directory.presenceAudience(session.accountId);
    for (const viewerAccountId of audience) {
      this.io.to(`account:${viewerAccountId}`).emit(SocketEvent.presenceChanged, {
        account_id: session.accountId,
        status,
        last_seen_ms: lastSeenMs,
      });
    }
  }

  // ------------------------------------------------------------------
  // Call signaling (WebRTC signaling ONLY — never media)
  // ------------------------------------------------------------------

  private async onCallSignal(
    socket: Socket,
    event: string,
    payload: unknown,
  ): Promise<void> {
    const data = socket.data as SocketData;
    const session = this.requireSession(socket, event);
    if (!session) return;
    if (!this.consumeRate(data, 'signaling')) {
      socket.emit(SocketEvent.systemError, { code: SocketErrorCode.rateLimited, event });
      return;
    }
    const record = this.payloadObject(payload);
    const peerAccountId = record['peer_account_id'];
    if (typeof peerAccountId !== 'string' || peerAccountId.length === 0) {
      socket.emit(SocketEvent.systemError, {
        code: SocketErrorCode.payloadInvalid,
        event,
      });
      return;
    }
    const decision = await this.authz.canSignalCall(session, peerAccountId);
    if (decision !== AuthzDecision.allow) {
      socket.emit(SocketEvent.systemError, { code: SocketErrorCode.forbidden, event });
      return;
    }
    // Relay opaque signaling data; identity fields are server-stamped
    // (client-supplied from_* fields are stripped — anti-spoof).
    const { peer_account_id: _peer, from_account_id: _fa, from_device_id: _fd, ...signal } = record;
    this.io.to(`account:${peerAccountId}`).emit(event, {
      from_account_id: session.accountId,
      from_device_id: session.deviceId,
      ...signal,
    });
  }

  // ------------------------------------------------------------------
  // Admin operations (also used by the admin HTTP API + tests)
  // ------------------------------------------------------------------

  /** Registers a device identity (bootstrap; production: Supabase). */
  async adminRegisterDevice(input: {
    accountId: string;
    deviceId: string;
    novaId: string;
    publicKeyBase64: string;
  }): Promise<void> {
    const publicKey = Uint8Array.from(Buffer.from(input.publicKeyBase64, 'base64'));
    const record = {
      accountId: input.accountId,
      deviceId: input.deviceId,
      novaId: input.novaId,
      ed25519PublicKey: publicKey,
      status: 'active' as const,
    };
    this.devices.register(record);
    await this.directory.upsertDevice(record);
  }

  /**
   * Revokes a device: registry + directory + every live session, fan-out
   * of device.revoked to the device room, then socket disconnects.
   * Future handshakes for this device fail (AUTH_FAILED).
   */
  async adminRevokeDevice(deviceId: string): Promise<{ revoked: boolean; sessionsKilled: number }> {
    const record = this.devices.byDeviceId(deviceId);
    const revokedLocally = this.devices.revoke(deviceId);
    await this.directory.revokeDevice(deviceId);
    const doomed = this.sessions.revokeByDevice(deviceId);
    if (record || revokedLocally) {
      this.io.to(`device:${deviceId}`).emit(SocketEvent.deviceRevoked, {
        device_id: deviceId,
        account_id: record?.accountId ?? '',
      });
    }
    // Let the device.revoked packet flush before closing the sockets.
    setTimeout(() => {
      void this.io.in(`device:${deviceId}`).fetchSockets().then((sockets) => {
        for (const socket of sockets) socket.disconnect(true);
      });
    }, 15);
    return { revoked: revokedLocally, sessionsKilled: doomed.length };
  }

  /** Revokes one session (remote logout of a single socket). */
  adminRevokeSession(sessionId: string): boolean {
    const session = this.sessions.revoke(sessionId);
    if (!session) return false;
    this.disconnectSocketKey(session.socketKey, SocketErrorCode.sessionExpired);
    return true;
  }

  async adminAddConversationMember(conversationId: string, accountId: string): Promise<void> {
    await this.directory.addConversationMember(conversationId, accountId);
  }

  async adminAddRelationship(a: string, b: string): Promise<void> {
    await this.directory.addRelationship(a, b);
  }

  async adminAllowPresence(subject: string, viewer: string): Promise<void> {
    await this.directory.allowPresence(subject, viewer);
  }

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------

  private payloadObject(payload: unknown): Record<string, unknown> {
    if (typeof payload === 'object' && payload !== null && !Array.isArray(payload)) {
      return payload as Record<string, unknown>;
    }
    return {};
  }

  private disconnectSocket(socket: Socket): void {
    // Small delay so the emitted error/failure packet flushes before close.
    setTimeout(() => socket.disconnect(true), 10);
  }

  private disconnectSocketKey(socketKey: string, code: string): void {
    const socket = this.io.of('/').sockets.get(socketKey);
    if (!socket) return;
    socket.emit(SocketEvent.systemError, { code });
    setTimeout(() => socket.disconnect(true), 10);
  }
}
