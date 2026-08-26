/**
 * FASE 0.5 — E2E: presence (§14), call signaling (§16), security logging
 * (§17) and concurrency (§13, §22).
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { World, sleep } from './world.js';
import type { NovaIdentity } from '../src/client/nova_client.js';
import { FORBIDDEN_LOG_KEYS } from '../src/logger.js';

const world = new World();

let alice: NovaIdentity;
let bob: NovaIdentity; // contact + presence audience of alice
let mallory: NovaIdentity; // stranger

before(async () => {
  await world.start();
  alice = await world.seedIdentity({ accountId: 'acc-PA', deviceId: 'dev-PA' });
  bob = await world.seedIdentity({ accountId: 'acc-PB', deviceId: 'dev-PB' });
  mallory = await world.seedIdentity({ accountId: 'acc-PM', deviceId: 'dev-PM' });
  await world.server.adminAllowPresence(alice.accountId, bob.accountId);
  await world.server.adminAddRelationship(alice.accountId, bob.accountId);
  await world.conversation('conv-presence', [alice.accountId, bob.accountId]);
});

after(async () => {
  await world.stop();
});

// ===================== PRESENCE =====================

test('1. presence online reaches only the privacy audience', async () => {
  const a = await world.connected(alice, 'A');
  const b = await world.connected(bob, 'B');
  const m = await world.connected(mallory, 'M');

  a.updatePresence('online');
  const changed = (await b.next('presence.changed')) as Record<string, unknown>;
  assert.equal(changed['account_id'], alice.accountId);
  assert.equal(changed['status'], 'online');
  assert.equal(typeof changed['last_seen_ms'], 'number');

  // Not a global broadcast: the stranger sees nothing.
  await m.expectNone('presence.changed', 300);

  a.disconnect();
  b.disconnect();
  m.disconnect();
});

test('2. disconnecting publishes offline + last_seen to the audience only', async () => {
  const a = await world.connected(alice, 'A');
  const b = await world.connected(bob, 'B');
  const m = await world.connected(mallory, 'M');
  a.updatePresence('online');
  await b.next('presence.changed');

  const before = Date.now();
  a.dropConnection(); // the network dies; no goodbye packet is sent

  const offline = (await b.next('presence.changed', 3000)) as Record<string, unknown>;
  assert.equal(offline['account_id'], alice.accountId);
  assert.equal(offline['status'], 'offline', 'the server derives offline itself');
  assert.ok(
    (offline['last_seen_ms'] as number) >= before,
    'last_seen reflects the disconnect moment',
  );
  await m.expectNone('presence.changed', 250);

  b.disconnect();
  m.disconnect();
});

test('3. presence is persisted and readable as last_seen', async () => {
  const a = await world.connected(alice, 'A');
  a.updatePresence('online');
  await sleep(80);
  const record = await world.server.store.getPresence(alice.accountId);
  assert.ok(record, 'presence is stored');
  assert.equal(record!.status, 'online');
  assert.ok(record!.lastSeenMs > 0);
  a.disconnect();
});

test('4. presence.update before authentication is refused', async () => {
  const client = world.client(mallory, 'M-early');
  client.connect();
  await client.next('connect');
  await client.nextChallenge();
  client.emitRaw('presence.update', { status: 'online' });
  const error = (await client.next('system.error')) as Record<string, unknown>;
  assert.equal(error['code'], 'FORBIDDEN');
  await client.next('disconnect');
  client.disconnect();
});

// ===================== CALL SIGNALING =====================

test('5. call.offer/answer/ice/end relay between contacts (signaling only)', async () => {
  const a = await world.connected(alice, 'A');
  const b = await world.connected(bob, 'B');

  a.signal('call.offer', bob.accountId, { sdp: 'v=0 fake-offer', call_id: 'call-1' });
  const offer = (await b.next('call.offer')) as Record<string, unknown>;
  assert.equal(offer['from_account_id'], alice.accountId);
  assert.equal(offer['from_device_id'], alice.deviceId);
  assert.equal(offer['sdp'], 'v=0 fake-offer');
  assert.equal(offer['call_id'], 'call-1');

  b.signal('call.answer', alice.accountId, { sdp: 'v=0 fake-answer', call_id: 'call-1' });
  const answer = (await a.next('call.answer')) as Record<string, unknown>;
  assert.equal(answer['from_account_id'], bob.accountId);

  a.signal('call.ice', bob.accountId, { candidate: 'candidate:1 udp', call_id: 'call-1' });
  const ice = (await b.next('call.ice')) as Record<string, unknown>;
  assert.equal(ice['candidate'], 'candidate:1 udp');

  b.signal('call.end', alice.accountId, { call_id: 'call-1', reason: 'hangup' });
  const end = (await a.next('call.end')) as Record<string, unknown>;
  assert.equal(end['reason'], 'hangup');

  a.disconnect();
  b.disconnect();
});

test('6. signaling to a NON-contact is refused', async () => {
  const m = await world.connected(mallory, 'M');
  const b = await world.connected(bob, 'B');
  m.signal('call.offer', bob.accountId, { sdp: 'v=0 spam' });
  const error = (await m.next('system.error')) as Record<string, unknown>;
  assert.equal(error['code'], 'FORBIDDEN');
  await b.expectNone('call.offer', 250);
  m.disconnect();
  b.disconnect();
});

test('7. the caller identity cannot be spoofed in a signaling payload', async () => {
  const a = await world.connected(alice, 'A');
  const b = await world.connected(bob, 'B');
  a.emitRaw('call.offer', {
    peer_account_id: bob.accountId,
    from_account_id: 'acc-someone-else',
    from_device_id: 'dev-someone-else',
    sdp: 'v=0 spoofed',
  });
  const offer = (await b.next('call.offer')) as Record<string, unknown>;
  assert.equal(offer['from_account_id'], alice.accountId, 'server-stamped identity wins');
  assert.equal(offer['from_device_id'], alice.deviceId);
  a.disconnect();
  b.disconnect();
});

test('8. signaling carries no media (the architecture stays signaling-only)', async () => {
  const a = await world.connected(alice, 'A');
  const b = await world.connected(bob, 'B');
  // A signaling packet is small metadata. Anything media-sized is capped
  // by maxHttpBufferSize; here we assert the contract shape.
  a.signal('call.offer', bob.accountId, { sdp: 'v=0 small', call_id: 'call-2' });
  const offer = (await b.next('call.offer')) as Record<string, unknown>;
  const size = Buffer.byteLength(JSON.stringify(offer));
  assert.ok(size < 4096, 'signaling packets are metadata, never media frames');
  a.disconnect();
  b.disconnect();
});

// ===================== SECURITY LOGGING =====================

test('9. logs never contain keys, signatures, challenges, sessions or plaintext', async () => {
  world.logs.clear();
  const a = await world.connected(alice, 'A');
  const b = await world.connected(bob, 'B');

  const secret = 'PLAINTEXT-ULTRA-SECRETO-1234';
  const ciphertext = Buffer.from(`cifrado:${secret}`).toString('base64');
  const { messageId } = await a.sendAndAwaitAck({
    conversationId: 'conv-presence',
    ciphertextBase64: ciphertext,
  });
  await b.next('message.new');
  b.markDelivered('conv-presence', messageId);
  await sleep(100);

  // A failed handshake also produces log lines.
  const impostor = world.client(mallory, 'M');
  impostor.connect();
  await impostor.authenticate({ accountId: 'acc-wrong' }).catch(() => undefined);
  await sleep(80);

  const text = world.logs.text();
  assert.ok(text.length > 0, 'the server does log something');
  assert.equal(text.includes(secret), false, 'no plaintext');
  assert.equal(text.includes(ciphertext), false, 'no ciphertext');
  assert.equal(text.includes(alice.publicKeyBase64), false, 'no key material');
  assert.equal(text.includes(a.session!.session_id), false, 'no session id');
  assert.equal(text.includes(alice.accountId), false, 'account ids are truncated');
  assert.equal(text.includes(messageId), false, 'message ids are truncated');

  // Structural check: no forbidden key ever appears with a value.
  for (const line of world.logs.lines) {
    const parsed = JSON.parse(line) as Record<string, unknown>;
    for (const key of Object.keys(parsed)) {
      assert.equal(
        FORBIDDEN_LOG_KEYS.has(key.toLowerCase()),
        false,
        `log line must not carry the field '${key}'`,
      );
    }
  }

  a.disconnect();
  b.disconnect();
  impostor.disconnect();
});

// ===================== RATE LIMITING =====================

test('10. message flooding is throttled by the server, not by the client', async () => {
  const identity = await world.seedIdentity({ accountId: 'acc-flood' });
  await world.conversation('conv-flood', [identity.accountId]);
  const flooder = await world.connected(identity, 'flooder');

  let limited = 0;
  const limit = world.server.config.messagePerMinute;
  for (let i = 0; i < limit + 12; i += 1) {
    flooder.emitRaw('message.send', {
      message_id: `flood-${i}`,
      conversation_id: 'conv-flood',
      ciphertext: Buffer.from(`f${i}`).toString('base64'),
      header_type: 'dr.v1',
    });
  }
  const deadline = Date.now() + 2500;
  while (Date.now() < deadline && limited === 0) {
    const error = await flooder
      .next('system.error', 400)
      .then((value) => value as Record<string, unknown>)
      .catch(() => null);
    if (error?.['code'] === 'RATE_LIMITED') limited += 1;
  }
  assert.ok(limited > 0, 'the server rejects the abusive burst');
  flooder.disconnect();
});

test('11. sync flooding is throttled', async () => {
  const identity = await world.seedIdentity({ accountId: 'acc-syncflood' });
  await world.conversation('conv-syncflood', [identity.accountId]);
  const client = await world.connected(identity, 'syncflood');

  for (let i = 0; i < world.server.config.syncPerMinute + 4; i += 1) {
    client.emitRaw('sync.request', { conversation_id: 'conv-syncflood', last_seq: 0 });
  }
  let limited = false;
  const deadline = Date.now() + 2500;
  while (Date.now() < deadline && !limited) {
    const error = await client
      .next('system.error', 400)
      .then((value) => value as Record<string, unknown>)
      .catch(() => null);
    if (error?.['code'] === 'RATE_LIMITED') limited = true;
  }
  assert.equal(limited, true);
  client.disconnect();
});

test('12. signaling flooding is throttled', async () => {
  const client = await world.connected(alice, 'A-signal-flood');
  for (let i = 0; i < world.server.config.signalingPerMinute + 6; i += 1) {
    client.signal('call.ice', bob.accountId, { candidate: `c-${i}` });
  }
  let limited = false;
  const deadline = Date.now() + 2500;
  while (Date.now() < deadline && !limited) {
    const error = await client
      .next('system.error', 400)
      .then((value) => value as Record<string, unknown>)
      .catch(() => null);
    if (error?.['code'] === 'RATE_LIMITED') limited = true;
  }
  assert.equal(limited, true);
  client.disconnect();
});

// ===================== CONCURRENCY =====================

test('13. 10 concurrent clients authenticate, message and disconnect cleanly', async () => {
  const conversation = 'conv-concurrent';
  const count = 10;
  const identities: NovaIdentity[] = [];
  for (let i = 0; i < count; i += 1) {
    identities.push(
      await world.seedIdentity({ accountId: `acc-conc-${i}`, deviceId: `dev-conc-${i}` }),
    );
  }
  await world.conversation(
    conversation,
    identities.map((identity) => identity.accountId),
  );

  // All ten handshake at the same time.
  const clients = await Promise.all(
    identities.map((identity, index) => world.connected(identity, `conc-${index}`)),
  );
  assert.equal(
    clients.every((client) => client.authenticated),
    true,
    'every concurrent handshake succeeds',
  );
  assert.equal(
    new Set(clients.map((client) => client.session!.session_id)).size,
    count,
    'every client gets its own distinct session',
  );

  // Each sends one message concurrently; each must be acked exactly once.
  const acks = await Promise.all(
    clients.map((client, index) =>
      client.sendAndAwaitAck({
        conversationId: conversation,
        ciphertextBase64: Buffer.from(`concurrent-${index}`).toString('base64'),
        timeoutMs: 8000,
      }),
    ),
  );
  const seqs = acks.map((entry) => entry.ack['server_seq'] as number);
  assert.equal(new Set(seqs).size, count, 'server_seq is unique under concurrency');
  assert.deepEqual(
    [...seqs].sort((x, y) => x - y),
    Array.from({ length: count }, (_, i) => Math.min(...seqs) + i),
    'sequences are contiguous — no lost or duplicated slot',
  );

  await sleep(300);
  // Every client received the other nine messages, each exactly once.
  for (const client of clients) {
    assert.equal(client.inbox.size, count - 1, 'fan-out reached every peer once');
  }

  for (const client of clients) client.disconnect();
  await sleep(150);
});

test('14. a reconnect storm of 10 clients is handled without cross-talk', async () => {
  const identities: NovaIdentity[] = [];
  for (let i = 0; i < 10; i += 1) {
    identities.push(await world.seedIdentity({ accountId: `acc-storm-${i}` }));
  }
  const clients = await Promise.all(
    identities.map((identity, index) => world.connected(identity, `storm-${index}`)),
  );
  const firstSessions = clients.map((client) => client.session!.session_id);

  await Promise.all(clients.map((client) => client.reconnect({ downtimeMs: 30 })));

  clients.forEach((client, index) => {
    assert.equal(client.authenticated, true, 'each client re-authenticated');
    assert.notEqual(
      client.session!.session_id,
      firstSessions[index],
      'each got a brand-new session',
    );
    assert.equal(
      client.session!.account_id,
      identities[index]!.accountId,
      'no identity cross-talk between concurrent handshakes',
    );
  });

  for (const client of clients) client.disconnect();
});
