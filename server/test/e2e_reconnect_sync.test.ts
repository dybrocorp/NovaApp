/**
 * FASE 0.5 — E2E: reconnection, network switching and sync (§9, §10, §15).
 *
 * Covers the full offline story:
 *   A online -> connection cut -> wait -> back -> new challenge -> new
 *   authentication -> sync -> conversation continues, with NO duplicated
 *   and NO missing messages.
 *
 * WiFi <-> mobile transitions are modelled the way the client models them
 * (`network_transition_handler.dart`): the transport is recycled and a
 * FULL re-handshake runs; a half-open socket is never trusted.
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { World, sleep } from './world.js';
import type { NovaIdentity } from '../src/client/nova_client.js';
import {
  RatchetSession,
  X3DHDevice,
  packEnvelope,
  unpackEnvelope,
  x3dhReceiver,
  x3dhSender,
} from '../src/client/e2ee.js';

const CONV = 'conv-reconnect';
const world = new World();

let identityA: NovaIdentity;
let identityB: NovaIdentity;
let ratchetA: RatchetSession;
let ratchetB: RatchetSession;

before(async () => {
  await world.start();
  identityA = await world.seedIdentity({ accountId: 'acc-RA', deviceId: 'dev-RA' });
  identityB = await world.seedIdentity({ accountId: 'acc-RB', deviceId: 'dev-RB' });
  await world.conversation(CONV, [identityA.accountId, identityB.accountId]);

  const deviceA = new X3DHDevice();
  const deviceB = new X3DHDevice();
  const sender = x3dhSender(deviceA, deviceB.bundle());
  const secretB = x3dhReceiver(deviceB, {
    senderIdentityRaw: deviceA.identity.publicRaw,
    senderEphemeralRaw: sender.ephemeralPublicRaw,
    usedOneTimePreKey: sender.usedOneTimePreKey,
  });
  ratchetA = RatchetSession.initSender(sender.sharedSecret, deviceB.signedPreKey.publicRaw);
  ratchetB = RatchetSession.initReceiver(secretB, deviceB.signedPreKey);
});

after(async () => {
  await world.stop();
});

test('1. a reconnect issues a NEW challenge and a NEW session (no blind reuse)', async () => {
  const a = await world.connected(identityA, 'A');
  const firstSession = a.session!.session_id;

  a.dropConnection();
  await sleep(80);
  a.connect();
  const challenge = await a.nextChallenge();
  assert.ok(challenge.challenge.length > 0, 'the server re-challenges on reconnect');
  const second = await a.authenticate({ challenge });

  assert.notEqual(second.session_id, firstSession, 'a fresh session id is minted');
  assert.equal(
    world.server.sessions.bySessionId(firstSession),
    null,
    'the old session is gone, never resurrected',
  );
  a.disconnect();
});

test('2. an old session id cannot be replayed after reconnecting', async () => {
  const a = await world.connected(identityA, 'A');
  const stale = a.session!.session_id;
  await a.reconnect({ downtimeMs: 50 });

  // Even naming the old session explicitly changes nothing: the server
  // authorizes by the session BOUND TO THE SOCKET, never by a client claim.
  a.emitRaw('sync.request', { conversation_id: CONV, last_seq: 0, session_id: stale });
  const response = (await a.next('sync.response')) as Record<string, unknown>;
  assert.equal(response['conversation_id'], CONV);
  assert.equal(world.server.sessions.bySessionId(stale), null);
  a.disconnect();
});

test('3. A offline -> B sends -> A returns -> sync recovers everything, once', async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');

  // A is up to date, then loses the network.
  const warmup = packEnvelope(ratchetA.encrypt('mensaje inicial'));
  await a.sendAndAwaitAck({ conversationId: CONV, ciphertextBase64: warmup });
  const live = (await b.next('message.new')) as Record<string, unknown>;
  ratchetB.decrypt(unpackEnvelope(live['ciphertext'] as string));

  a.dropConnection();

  // B keeps talking while A is away.
  const missed = ['offline 1', 'offline 2', 'offline 3'];
  const expected: string[] = [];
  for (const text of missed) {
    const ciphertextBase64 = packEnvelope(ratchetB.encrypt(text));
    const { messageId } = await b.sendAndAwaitAck({ conversationId: CONV, ciphertextBase64 });
    expected.push(messageId);
  }

  // A comes back: reconnect -> re-auth -> sync.
  await sleep(60);
  a.connect();
  await a.authenticate();
  const response = await a.sync(CONV);
  const events = response['events'] as Array<Record<string, unknown>>;

  const recovered = events.filter((event) => event['type'] === 'message.new');
  const recoveredIds = recovered.map((event) => event['message_id']);
  for (const id of expected) {
    assert.ok(recoveredIds.includes(id), `sync must recover ${id}`);
  }

  // The recovered payloads decrypt with the SAME ratchet — the sync path
  // carries the identical opaque envelope the live path carries.
  const texts = recovered
    .filter((event) => expected.includes(event['message_id'] as string))
    .sort((x, y) => (x['server_seq'] as number) - (y['server_seq'] as number))
    .map((event) => ratchetA.decrypt(unpackEnvelope(event['ciphertext'] as string)));
  assert.deepEqual(texts, missed, 'A recovers exactly what B sent, in order');

  // Re-syncing from the new cursor returns nothing: no duplicates.
  const again = await a.sync(CONV);
  const againEvents = again['events'] as unknown[];
  assert.deepEqual(againEvents, [], 'an up-to-date cursor replays nothing');

  a.disconnect();
  b.disconnect();
});

test('4. sync events are ordered and gap-free (server ordering authority)', async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');
  const conversation = 'conv-order-sync';
  await world.conversation(conversation, [identityA.accountId, identityB.accountId]);
  await a.reconnect({ downtimeMs: 20 }); // pick up the new membership
  await b.reconnect({ downtimeMs: 20 });

  b.dropConnection();
  for (let i = 0; i < 6; i += 1) {
    await a.sendAndAwaitAck({
      conversationId: conversation,
      ciphertextBase64: Buffer.from(`blob-${i}`).toString('base64'),
    });
  }
  b.connect();
  await b.authenticate();
  const response = await b.sync(conversation);
  const events = (response['events'] as Array<Record<string, unknown>>).filter(
    (event) => event['type'] === 'message.new',
  );
  assert.equal(events.length, 6);
  const logSeqs = events.map((event) => event['log_seq'] as number);
  assert.deepEqual(logSeqs, [...logSeqs].sort((x, y) => x - y), 'ordered by log_seq');
  // Contiguous: no missing event inside the returned window.
  for (let i = 1; i < logSeqs.length; i += 1) {
    assert.equal(logSeqs[i]! - logSeqs[i - 1]!, 1, 'no gaps in the replayed log');
  }

  a.disconnect();
  b.disconnect();
});

test('5. receipts emitted while offline are recovered by sync', async () => {
  const conversation = 'conv-receipt-sync';
  await world.conversation(conversation, [identityA.accountId, identityB.accountId]);
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');

  const { messageId, ack } = await a.sendAndAwaitAck({
    conversationId: conversation,
    ciphertextBase64: Buffer.from('para recibo').toString('base64'),
  });
  await b.next('message.new');

  // A goes offline BEFORE B acknowledges.
  await a.sync(conversation); // A's cursor is now at the message
  a.dropConnection();
  b.markDelivered(conversation, messageId);
  b.markRead(conversation, ack['server_seq'] as number);
  await sleep(80);

  a.connect();
  await a.authenticate();
  const response = await a.sync(conversation);
  const events = response['events'] as Array<Record<string, unknown>>;
  const types = events.map((event) => event['type']);
  assert.ok(types.includes('message.delivered'), 'delivered receipt survives the outage');
  assert.ok(types.includes('message.read'), 'read receipt survives the outage');

  a.disconnect();
  b.disconnect();
});

test('6. WiFi -> mobile: recycle + re-auth, conversation continues intact', async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');

  const before = packEnvelope(ratchetA.encrypt('sobre wifi'));
  await a.sendAndAwaitAck({ conversationId: CONV, ciphertextBase64: before });
  const wifiMsg = (await b.next('message.new')) as Record<string, unknown>;
  assert.equal(ratchetB.decrypt(unpackEnvelope(wifiMsg['ciphertext'] as string)), 'sobre wifi');

  // Network switch: the old transport is abandoned, not reused.
  const sessionOnWifi = a.session!.session_id;
  await a.reconnect({ downtimeMs: 0 });
  assert.notEqual(a.session!.session_id, sessionOnWifi);

  const after = packEnvelope(ratchetA.encrypt('sobre datos moviles'));
  await a.sendAndAwaitAck({ conversationId: CONV, ciphertextBase64: after });
  const mobileMsg = (await b.next('message.new')) as Record<string, unknown>;
  assert.equal(
    ratchetB.decrypt(unpackEnvelope(mobileMsg['ciphertext'] as string)),
    'sobre datos moviles',
  );

  a.disconnect();
  b.disconnect();
});

test('7. mobile -> WiFi mid-send: the outbox retries without duplicating', async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');
  const inboxBefore = b.inbox.size;

  const ciphertextBase64 = packEnvelope(ratchetA.encrypt('mensaje durante el cambio de red'));
  const messageId = `msg-switch-${Date.now()}`;

  // The send races the network switch: it may or may not reach the server.
  a.sendEnvelope({ conversationId: CONV, ciphertextBase64, messageId });
  a.dropConnection(); // network flips before the ack is observed

  a.connect();
  await a.authenticate();
  const resent = a.flushOutbox(); // same message_id — idempotent retry
  assert.ok(resent.includes(messageId), 'the un-acked envelope is retried');
  await a.waitForAck(messageId);

  await sleep(250);
  const delivered = [...b.inbox.keys()].filter((id) => id === messageId);
  assert.equal(delivered.length, 1, 'B receives it exactly once across the switch');
  assert.equal(b.inbox.size, inboxBefore + 1, 'no phantom extra messages');

  a.disconnect();
  b.disconnect();
});

test('8. account-wide sync recovers conversations the client never opened', async () => {
  const first = 'conv-wide-1';
  const second = 'conv-wide-2';
  await world.conversation(first, [identityA.accountId, identityB.accountId]);
  await world.conversation(second, [identityA.accountId, identityB.accountId]);

  const b = await world.connected(identityB, 'B');
  const a = await world.connected(identityA, 'A');
  a.dropConnection();

  await b.sendAndAwaitAck({
    conversationId: first,
    ciphertextBase64: Buffer.from('en la primera').toString('base64'),
  });
  await b.sendAndAwaitAck({
    conversationId: second,
    ciphertextBase64: Buffer.from('en la segunda').toString('base64'),
  });

  a.connect();
  await a.authenticate();
  // No conversation_id: "tell me everything I missed".
  const response = await a.sync();
  const conversations = response['conversations'] as Array<Record<string, unknown>>;
  const ids = conversations.map((entry) => entry['conversation_id']);
  assert.ok(ids.includes(first) && ids.includes(second), 'both conversations are covered');

  const recovered = conversations
    .flatMap((entry) => entry['events'] as Array<Record<string, unknown>>)
    .filter((event) => event['type'] === 'message.new');
  assert.ok(recovered.length >= 2, 'messages from unopened chats are recovered');

  a.disconnect();
  b.disconnect();
});

test('9. sync is paginated and the cursor never skips events', async () => {
  const conversation = 'conv-paged';
  await world.conversation(conversation, [identityA.accountId, identityB.accountId]);
  const paged = await world.connected(identityA, 'A-paged');
  const sender = await world.connected(identityB, 'B-paged');

  const total = 12;
  for (let i = 0; i < total; i += 1) {
    await sender.sendAndAwaitAck({
      conversationId: conversation,
      ciphertextBase64: Buffer.from(`paged-${i}`).toString('base64'),
    });
  }

  // Force tiny pages by asking with an explicit cursor walk.
  const collected: number[] = [];
  let cursor = 0;
  for (let round = 0; round < 20; round += 1) {
    paged.emitRaw('sync.request', { conversation_id: conversation, last_seq: cursor });
    const response = (await paged.next('sync.response')) as Record<string, unknown>;
    const events = response['events'] as Array<Record<string, unknown>>;
    for (const event of events) collected.push(event['log_seq'] as number);
    const next = response['cursor'] as number;
    if (next === cursor) break;
    cursor = next;
    if ((response['has_more'] as boolean) !== true) break;
  }
  const messageEvents = new Set(collected);
  assert.equal(messageEvents.size, collected.length, 'no event delivered twice');
  assert.ok(collected.length >= total, 'every event is eventually delivered');

  paged.disconnect();
  sender.disconnect();
});

test('10. server restart: clients reconnect and re-authenticate cleanly', async () => {
  const restarting = new World();
  await restarting.start();
  try {
    const identity = await restarting.seedIdentity({ accountId: 'acc-restart' });
    await restarting.conversation('conv-restart', [identity.accountId]);
    const client = await restarting.connected(identity, 'restart');
    const firstSession = client.session!.session_id;

    // The server announces the shutdown before closing (graceful path).
    const shutdownSeen = client.next('system.shutdown', 2000).then(
      () => true,
      () => false,
    );
    await restarting.server.stop();
    assert.equal(await shutdownSeen, true, 'clients are warned before the close');
    await client.next('disconnect');
    assert.equal(client.authenticated, false, 'the session dies with the server');

    // A fresh server on the same port accepts a full new handshake.
    await restarting.start();
    await restarting.server.adminRegisterDevice({
      accountId: identity.accountId,
      deviceId: identity.deviceId,
      novaId: identity.novaId,
      publicKeyBase64: identity.publicKeyBase64,
    });
    const revived = await restarting.connected(identity, 'restart-2');
    assert.notEqual(revived.session!.session_id, firstSession);
    assert.equal(revived.authenticated, true);
  } finally {
    await restarting.stop();
  }
});
