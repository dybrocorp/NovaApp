/**
 * E2E helpers: real Socket.IO clients over loopback WebSockets against an
 * in-process RealtimeServer. Ed25519 identities are generated with
 * node:crypto and sign the exact NOVA_AUTH_v1 canonical message the
 * Flutter client signs (lib/core/socket/auth/auth_signer.dart) — so these
 * tests exercise the same wire contract the app speaks.
 */
import { generateKeyPairSync, sign as cryptoSign, type KeyObject } from 'node:crypto';
import { io, type Socket } from 'socket.io-client';
import type { RealtimeServer } from '../src/realtime_server.js';

export const DEFAULT_TIMEOUT_MS = 5000;

export interface Identity {
  accountId: string;
  deviceId: string;
  novaId: string;
  privateKey: KeyObject;
  publicKeyBase64: string; // raw 32-byte Ed25519, base64
}

export interface ChallengeWire {
  challenge_id: string;
  challenge: string;
  expires_at_ms: number;
}

export class AuthError extends Error {
  constructor(readonly code: string) {
    super(`auth.failure: ${code}`);
  }
}

let idCounter = 0;
const nextId = (prefix: string): string => `${prefix}-${++idCounter}`;

export function makeIdentity(options: {
  accountId?: string;
  deviceId?: string;
  novaId?: string;
} = {}): Identity {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const raw = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32);
  return {
    accountId: options.accountId ?? nextId('acc'),
    deviceId: options.deviceId ?? nextId('dev'),
    novaId: options.novaId ?? `NOVA-${Math.random().toString(36).slice(2, 9).toUpperCase()}`,
    privateKey,
    publicKeyBase64: Buffer.from(raw).toString('base64'),
  };
}

export async function registerIdentity(server: RealtimeServer, identity: Identity): Promise<void> {
  await server.adminRegisterDevice({
    accountId: identity.accountId,
    deviceId: identity.deviceId,
    novaId: identity.novaId,
    publicKeyBase64: identity.publicKeyBase64,
  });
}

export async function seedUser(
  server: RealtimeServer,
  options: { accountId?: string; deviceId?: string } = {},
): Promise<Identity> {
  const identity = makeIdentity(options);
  await registerIdentity(server, identity);
  return identity;
}

export async function seedConversation(
  server: RealtimeServer,
  conversationId: string,
  accountIds: string[],
): Promise<void> {
  for (const accountId of accountIds) {
    await server.adminAddConversationMember(conversationId, accountId);
  }
}

/** Canonical message signed by the client (auth_signer.dart parity). */
export function canonicalAuthMessage(input: {
  accountId: string;
  deviceId: string;
  novaId: string;
  challengeId: string;
  challengeBase64: string;
}): string {
  return [
    'NOVA_AUTH_v1',
    input.accountId,
    input.deviceId,
    input.novaId,
    input.challengeId,
    input.challengeBase64,
  ].join('|');
}

export function signCanonical(identity: Identity, challenge: ChallengeWire, overrides: {
  accountId?: string;
  deviceId?: string;
  novaId?: string;
  signingKey?: KeyObject;
} = {}): string {
  const message = canonicalAuthMessage({
    accountId: overrides.accountId ?? identity.accountId,
    deviceId: overrides.deviceId ?? identity.deviceId,
    novaId: overrides.novaId ?? identity.novaId,
    challengeId: challenge.challenge_id,
    challengeBase64: challenge.challenge,
  });
  const key = overrides.signingKey ?? identity.privateKey;
  return cryptoSign(null, Buffer.from(message, 'utf8'), key).toString('base64');
}

export interface AuthSuccessWire {
  session_id: string;
  account_id: string;
  device_id: string;
  nova_id: string;
  expires_at_ms: number;
}

interface Collector {
  count(): number;
  values(): unknown[];
  stop(): void;
}

/** A connected test client. All events are buffered from creation — no races. */
export class TestClient {
  private readonly queues = new Map<string, unknown[]>();
  private readonly waiters = new Map<string, Array<(value: unknown) => void>>();

  private constructor(readonly socket: Socket) {
    // socket.io-client dispatches events the moment they arrive; a test
    // attaches listeners later (after other awaits), so EVERY event is
    // captured into a per-event queue at creation and replayed on demand.
    socket.on('connect', () => this.enqueue('connect', undefined));
    socket.on('disconnect', (reason) => this.enqueue('disconnect', reason));
    socket.on('connect_error', (error) =>
      this.enqueue('connect_error', (error as Error)?.message ?? 'connect_error'),
    );
    socket.onAny((event, ...args) => {
      // Server events carry exactly ONE payload object (socket.io-client
      // may append a trailing ack callback — dropped here).
      this.enqueue(event, args[0]);
    });
  }

  static connect(port: number): TestClient {
    const socket = io(`http://127.0.0.1:${port}`, {
      transports: ['websocket'], // production transport policy — no polling
      reconnection: false,
      forceNew: true,
      timeout: 4000,
    });
    return new TestClient(socket);
  }

  private enqueue(event: string, payload: unknown): void {
    const queue = this.queues.get(event) ?? [];
    queue.push(payload);
    this.queues.set(event, queue);
    const waiter = this.waiters.get(event)?.shift();
    if (waiter) {
      const value = this.queues.get(event)!.shift();
      waiter(value);
    }
  }

  async ready(): Promise<void> {
    await this.next('connect');
  }

  async challenge(timeoutMs = DEFAULT_TIMEOUT_MS): Promise<ChallengeWire> {
    return (await this.next('auth.challenge', timeoutMs)) as ChallengeWire;
  }

  /** Emits a raw auth.response payload; resolves with auth.success. */
  async respondRaw(payload: Record<string, unknown>, timeoutMs = DEFAULT_TIMEOUT_MS): Promise<AuthSuccessWire> {
    this.socket.emit('auth.response', payload);
    const outcome = await this.race(
      ['auth.success', 'auth.failure', 'disconnect'],
      timeoutMs,
    ) as { event: string; payload: unknown };
    if (outcome.event === 'auth.success') return outcome.payload as AuthSuccessWire;
    if (outcome.event === 'auth.failure') {
      const code = (outcome.payload as { code?: string })?.code ?? 'AUTH_FAILED';
      throw new AuthError(code);
    }
    throw new AuthError('DISCONNECTED');
  }

  /** Full happy-path handshake for [identity] against the live challenge. */
  async authenticate(
    identity: Identity,
    overrides: {
      signatureBase64?: string;
      accountId?: string;
      deviceId?: string;
      novaId?: string;
      signingKey?: KeyObject;
    } = {},
  ): Promise<AuthSuccessWire> {
    await this.ready();
    const challenge = await this.challenge();
    const payload: Record<string, unknown> = {
      challenge_id: challenge.challenge_id,
      signature:
        overrides.signatureBase64 ??
        signCanonical(identity, challenge, {
          accountId: overrides.accountId,
          deviceId: overrides.deviceId,
          novaId: overrides.novaId,
          signingKey: overrides.signingKey,
        }),
      account_id: overrides.accountId ?? identity.accountId,
      device_id: overrides.deviceId ?? identity.deviceId,
      nova_id: overrides.novaId ?? identity.novaId,
      ts_ms: Date.now(),
    };
    return this.respondRaw(payload);
  }

  emit(event: string, payload: unknown): void {
    this.socket.emit(event, payload);
  }

  /** Resolves with {event, payload} for the first of [events] to fire. */
  race(events: string[], timeoutMs = DEFAULT_TIMEOUT_MS): Promise<{ event: string; payload: unknown }> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        cleanup();
        reject(new Error(`timeout waiting for one of: ${events.join(', ')}`));
      }, timeoutMs);
      const handlers = new Map<string, (payload: unknown) => void>();
      const cleanup = () => {
        clearTimeout(timer);
        for (const [event, handler] of handlers) this.socket.off(event, handler);
      };
      for (const event of events) {
        const handler = (payload: unknown) => {
          cleanup();
          resolve({ event, payload });
        };
        handlers.set(event, handler);
        this.socket.on(event, handler);
      }
    });
  }

  next<T = unknown>(event: string, timeoutMs = DEFAULT_TIMEOUT_MS): Promise<T> {
    const queue = this.queues.get(event);
    if (queue && queue.length > 0) {
      return Promise.resolve(queue.shift() as T);
    }
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        const list = this.waiters.get(event) ?? [];
        this.waiters.set(event, list.filter((entry) => entry !== waiter));
        reject(new Error(`timeout waiting for: ${event}`));
      }, timeoutMs);
      const waiter = (value: unknown) => {
        clearTimeout(timer);
        resolve(value as T);
      };
      const list = this.waiters.get(event) ?? [];
      list.push(waiter);
      this.waiters.set(event, list);
    });
  }

  /** Asserts that [event] does NOT fire within [ms] (buffer-aware). */
  async expectNone(event: string, ms = 250): Promise<void> {
    const queued = this.queues.get(event) ?? [];
    if (queued.length > 0) {
      throw new Error(`expected no "${event}", but one arrived`);
    }
    const arrived = await new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => {
        this.socket.off(event, handler);
        resolve(false);
      }, ms);
      const handler = () => {
        clearTimeout(timer);
        this.socket.off(event, handler);
        resolve(true);
      };
      this.socket.on(event, handler);
    });
    if (arrived) throw new Error(`expected no "${event}", but one arrived`);
  }

  collect(event: string): Collector {
    const values: unknown[] = [];
    const handler = (payload: unknown) => values.push(payload);
    this.socket.on(event, handler);
    return {
      count: () => values.length,
      values: () => [...values],
      stop: () => this.socket.off(event, handler),
    };
  }

  /** Emits a message.send envelope and resolves on its message.ack. */
  async sendMessage(input: {
    conversationId: string;
    identity: Identity;
    messageId?: string;
    ciphertextBase64?: string;
    headerType?: string;
    overrides?: Record<string, unknown>;
  }): Promise<{ messageId: string; ack: { message_id: string; server_seq: number; duplicate?: boolean } }> {
    const messageId = input.messageId ?? `msg-${Math.random().toString(36).slice(2)}`;
    const envelope = {
      message_id: messageId,
      conversation_id: input.conversationId,
      sender_device_id: input.identity.deviceId,
      ciphertext: input.ciphertextBase64 ?? Buffer.from(`ciphertext:${messageId}`).toString('base64'),
      header_type: input.headerType ?? 'dr.v1',
      ...input.overrides,
    };
    this.socket.emit('message.send', envelope);
    const ack = (await this.next('message.ack')) as { message_id: string; server_seq: number };
    return { messageId, ack };
  }

  onDisconnect(timeoutMs = DEFAULT_TIMEOUT_MS): Promise<string> {
    return this.next<string>('disconnect', timeoutMs);
  }

  disconnect(): void {
    this.socket.disconnect();
  }

  get isConnected(): boolean {
    return this.socket.connected;
  }
}

/** Suite fixture: one server + client tracking + automatic teardown. */
export class TestWorld {
  server!: RealtimeServer;
  port!: number;
  private readonly clients: TestClient[] = [];

  constructor(private readonly serverFactory: () => RealtimeServer) {}

  async start(): Promise<void> {
    this.server = this.serverFactory();
    this.port = await this.server.start();
  }

  client(): TestClient {
    const client = TestClient.connect(this.port);
    this.clients.push(client);
    return client;
  }

  async stop(): Promise<void> {
    for (const client of this.clients) client.disconnect();
    this.clients.length = 0;
    await this.server.stop();
  }
}
