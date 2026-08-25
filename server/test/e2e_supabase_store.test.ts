/**
 * FASE 0.5 — E2E: the SUPABASE leg of the topology (§18).
 *
 *   CLIENT A -> WSS -> REALTIME SERVER -> SUPABASE (PostgREST)
 *                                      -> REALTIME SERVER -> WSS -> CLIENT B
 *
 * A real Supabase project is not reachable from CI, so this suite runs the
 * production `SupabaseRealtimeStore` against an in-process PostgREST
 * DOUBLE that speaks the same HTTP contract (same paths, same headers,
 * same RPC shape) and is backed by real SQL-like semantics.
 *
 * What this proves:
 *   * the server's Supabase code path works end to end (A -> Supabase -> B);
 *   * every request carries the SERVICE ROLE key in apikey + Authorization;
 *   * the service role key NEVER reaches a client or a log line;
 *   * ONLY opaque ciphertext + metadata is persisted;
 *   * sequences come from the atomic RPCs, and are unique under load.
 *
 * What it does NOT prove: real Postgres RLS enforcement and real network
 * behavior. Those require a live project — see
 * docs/REALTIME_PRODUCTION_CHECKLIST.md.
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Server } from 'node:http';
import { RealtimeServer } from '../src/realtime_server.js';
import { SupabaseRealtimeStore } from '../src/store/supabase_store.js';
import { MemoryDirectory } from '../src/directory/memory_directory.js';
import { NovaClient, createIdentity, type NovaIdentity } from '../src/client/nova_client.js';
import { LogCapture, sleep } from './world.js';
import { packEnvelope, unpackEnvelope, establishSessions } from '../src/client/e2ee.js';

const SERVICE_ROLE_KEY = 'service-role-key-THIS-MUST-NEVER-LEAK';
const CONV = 'conv-supabase';

/** Minimal PostgREST double backed by in-memory "tables". */
class FakePostgrest {
  readonly tables = new Map<string, Array<Record<string, unknown>>>();
  readonly cursors = new Map<string, { last_seq: number; last_log_seq: number }>();
  readonly requests: Array<{ method: string; path: string; auth: string; apikey: string }> = [];
  private server!: Server;
  url = '';

  private rows(table: string): Array<Record<string, unknown>> {
    if (!this.tables.has(table)) this.tables.set(table, []);
    return this.tables.get(table)!;
  }

  async start(): Promise<void> {
    this.server = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (chunk: Buffer) => chunks.push(chunk));
      req.on('end', () => {
        const url = new URL(req.url ?? '/', 'http://localhost');
        this.requests.push({
          method: req.method ?? 'GET',
          path: url.pathname,
          auth: String(req.headers.authorization ?? ''),
          apikey: String(req.headers.apikey ?? ''),
        });
        // PostgREST rejects anything without a valid key.
        if (
          req.headers.apikey !== SERVICE_ROLE_KEY ||
          req.headers.authorization !== `Bearer ${SERVICE_ROLE_KEY}`
        ) {
          res.writeHead(401).end(JSON.stringify({ message: 'unauthorized' }));
          return;
        }
        const body = chunks.length > 0 ? JSON.parse(Buffer.concat(chunks).toString()) : undefined;
        try {
          const payload = this.route(req.method ?? 'GET', url, body);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(payload));
        } catch (error) {
          res.writeHead(400).end(JSON.stringify({ message: (error as Error).message }));
        }
      });
    });
    await new Promise<void>((resolve) => this.server.listen(0, '127.0.0.1', resolve));
    const address = this.server.address();
    this.url = `http://127.0.0.1:${typeof address === 'object' && address ? address.port : 0}`;
  }

  private route(method: string, url: URL, body: unknown): unknown {
    const segments = url.pathname.split('/').filter(Boolean); // rest,v1,<table|rpc>
    if (segments[2] === 'rpc') {
      const fn = segments[3];
      const conversationId = String((body as Record<string, unknown>)['p_conversation_id']);
      const entry = this.cursors.get(conversationId) ?? { last_seq: 0, last_log_seq: 0 };
      if (fn === 'nova_next_seq') entry.last_seq += 1;
      else if (fn === 'nova_next_log_seq') entry.last_log_seq += 1;
      else throw new Error(`unknown rpc ${fn}`);
      this.cursors.set(conversationId, entry);
      return fn === 'nova_next_seq' ? entry.last_seq : entry.last_log_seq;
    }
    const table = segments[2]!;
    if (method === 'POST') {
      const incoming = Array.isArray(body) ? body : [body];
      for (const row of incoming) {
        this.rows(table).push(row as Record<string, unknown>);
      }
      return [];
    }
    if (method === 'GET') {
      if (table === 'conversation_cursors') {
        const filter = url.searchParams.get('conversation_id') ?? '';
        const id = filter.replace('eq.', '');
        const entry = this.cursors.get(id);
        return entry ? [{ conversation_id: id, ...entry }] : [];
      }
      let rows = [...this.rows(table)];
      for (const [key, raw] of url.searchParams) {
        if (['select', 'limit', 'order', 'on_conflict'].includes(key)) continue;
        if (raw.startsWith('eq.')) {
          const value = raw.slice(3);
          rows = rows.filter((row) => String(row[key]) === value);
        } else if (raw.startsWith('gt.')) {
          const value = Number(raw.slice(3));
          rows = rows.filter((row) => Number(row[key]) > value);
        }
      }
      const order = url.searchParams.get('order');
      if (order) {
        const [field] = order.split('.');
        rows.sort((a, b) => Number(a[field!]) - Number(b[field!]));
      }
      const limit = url.searchParams.get('limit');
      if (limit) rows = rows.slice(0, Number(limit));
      return rows;
    }
    if (method === 'PATCH') {
      return [];
    }
    throw new Error(`unsupported ${method}`);
  }

  async stop(): Promise<void> {
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
  }
}

const postgrest = new FakePostgrest();
const logs = new LogCapture();
let server: RealtimeServer;
let port: number;
let identityA: NovaIdentity;
let identityB: NovaIdentity;

before(async () => {
  await postgrest.start();
  const store = new SupabaseRealtimeStore(postgrest.url, SERVICE_ROLE_KEY);
  server = new RealtimeServer({
    directory: new MemoryDirectory(),
    store,
    logSink: logs.sink,
  });
  port = await server.start({ host: '127.0.0.1' });

  identityA = createIdentity({ accountId: 'acc-SA', deviceId: 'dev-SA' });
  identityB = createIdentity({ accountId: 'acc-SB', deviceId: 'dev-SB' });
  for (const identity of [identityA, identityB]) {
    await server.adminRegisterDevice({
      accountId: identity.accountId,
      deviceId: identity.deviceId,
      novaId: identity.novaId,
      publicKeyBase64: identity.publicKeyBase64,
    });
    await server.adminAddConversationMember(CONV, identity.accountId);
  }
});

after(async () => {
  await server.stop();
  await postgrest.stop();
});

function client(identity: NovaIdentity, name: string): NovaClient {
  return new NovaClient({ url: `http://127.0.0.1:${port}`, identity, name });
}

async function connected(identity: NovaIdentity, name: string): Promise<NovaClient> {
  const instance = client(identity, name);
  instance.connect();
  await instance.authenticate();
  return instance;
}

test('1. A -> Supabase -> B: the full round trip persists and delivers', async () => {
  const { alice, bob } = establishSessions();
  const a = await connected(identityA, 'A');
  const b = await connected(identityB, 'B');

  const plaintext = 'mensaje que viaja por Supabase';
  const ciphertextBase64 = packEnvelope(alice.encrypt(plaintext));
  const { messageId, ack } = await a.sendAndAwaitAck({ conversationId: CONV, ciphertextBase64 });
  assert.equal(typeof ack['server_seq'], 'number');

  const inbound = (await b.next('message.new')) as Record<string, unknown>;
  assert.equal(inbound['message_id'], messageId);
  assert.equal(bob.decrypt(unpackEnvelope(inbound['ciphertext'] as string)), plaintext);

  // It really went through the Supabase tables.
  const rows = postgrest.tables.get('realtime_messages') ?? [];
  const persisted = rows.find((row) => row['message_id'] === messageId);
  assert.ok(persisted, 'the message reached the Supabase realtime_messages table');
  assert.equal(persisted!['ciphertext'], ciphertextBase64);
  assert.equal(
    JSON.stringify(persisted).includes(plaintext),
    false,
    'Supabase stores ciphertext only — never plaintext',
  );

  a.disconnect();
  b.disconnect();
});

test('2. every Supabase request authenticates with the service role key', async () => {
  assert.ok(postgrest.requests.length > 0, 'the server really talked to PostgREST');
  for (const request of postgrest.requests) {
    assert.equal(request.apikey, SERVICE_ROLE_KEY);
    assert.equal(request.auth, `Bearer ${SERVICE_ROLE_KEY}`);
  }
});

test('3. the service role key never reaches a client or a log line', async () => {
  const a = await connected(identityA, 'A');
  const b = await connected(identityB, 'B');
  const observed: string[] = [];
  a.socketTap((event, payload) => observed.push(`${event}:${JSON.stringify(payload ?? {})}`));

  await a.sendAndAwaitAck({
    conversationId: CONV,
    ciphertextBase64: Buffer.from('otra vez').toString('base64'),
  });
  await b.next('message.new');
  await sleep(80);

  const clientTraffic = observed.join('\n');
  assert.equal(
    clientTraffic.includes(SERVICE_ROLE_KEY),
    false,
    'the service role key is never sent to a client',
  );
  assert.equal(
    logs.text().includes(SERVICE_ROLE_KEY),
    false,
    'the service role key is never logged',
  );
  assert.equal(
    logs.text().includes(postgrest.url),
    false,
    'backend endpoints are not echoed into logs',
  );

  a.disconnect();
  b.disconnect();
});

test('4. sequences come from the atomic RPC and stay unique under concurrency', async () => {
  const conversation = 'conv-supabase-conc';
  const identities: NovaIdentity[] = [];
  for (let i = 0; i < 8; i += 1) {
    const identity = createIdentity({
      accountId: `acc-sconc-${i}`,
      deviceId: `dev-sconc-${i}`,
    });
    await server.adminRegisterDevice({
      accountId: identity.accountId,
      deviceId: identity.deviceId,
      novaId: identity.novaId,
      publicKeyBase64: identity.publicKeyBase64,
    });
    await server.adminAddConversationMember(conversation, identity.accountId);
    identities.push(identity);
  }
  const clients = await Promise.all(
    identities.map((identity, index) => connected(identity, `sconc-${index}`)),
  );
  const acks = await Promise.all(
    clients.map((instance, index) =>
      instance.sendAndAwaitAck({
        conversationId: conversation,
        ciphertextBase64: Buffer.from(`s-${index}`).toString('base64'),
        timeoutMs: 8000,
      }),
    ),
  );
  const seqs = acks.map((entry) => entry.ack['server_seq'] as number);
  assert.equal(new Set(seqs).size, seqs.length, 'the RPC never mints a duplicate seq');

  for (const instance of clients) instance.disconnect();
});

test('5. sync replays from the Supabase event log', async () => {
  const { alice, bob } = establishSessions();
  const a = await connected(identityA, 'A');
  const b = await connected(identityB, 'B');
  b.dropConnection();

  const texts = ['supa 1', 'supa 2'];
  for (const text of texts) {
    await a.sendAndAwaitAck({
      conversationId: CONV,
      ciphertextBase64: packEnvelope(alice.encrypt(text)),
    });
  }

  b.connect();
  await b.authenticate();
  const response = await b.sync(CONV);
  const events = (response['events'] as Array<Record<string, unknown>>).filter(
    (event) => event['type'] === 'message.new',
  );
  const recovered = events
    .slice(-2)
    .map((event) => bob.decrypt(unpackEnvelope(event['ciphertext'] as string)));
  assert.deepEqual(recovered, texts, 'the event log round-trips through Supabase');

  a.disconnect();
  b.disconnect();
});

test('6. a broken/absent sequence RPC fails CLOSED (no silent duplicate seq)', async () => {
  const broken = new SupabaseRealtimeStore(`${postgrest.url}/nonexistent`, SERVICE_ROLE_KEY);
  await assert.rejects(
    () => broken.nextSeq('conv-x'),
    /rpc failed|invalid sequence/,
    'a missing RPC must raise, never fall back to a guessed sequence',
  );
});
