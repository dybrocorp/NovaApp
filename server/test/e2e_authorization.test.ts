/**
 * FASE 0.5 — E2E: authorization (§12) and session security (§11).
 *
 * Authentication != authorization. An authenticated account A must NOT be
 * able to reach ANY of B's state: conversations, messages, identity,
 * device, session or rooms.
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { World, sleep } from './world.js';
import type { NovaIdentity } from '../src/client/nova_client.js';

const CONV_AB = 'conv-authz-ab';
const CONV_B_PRIVATE = 'conv-authz-b-private';
const world = new World();

let identityA: NovaIdentity;
let identityB: NovaIdentity;
let identityC: NovaIdentity; // B's peer in the private conversation

before(async () => {
  await world.start();
  identityA = await world.seedIdentity({ accountId: 'acc-ZA', deviceId: 'dev-ZA' });
  identityB = await world.seedIdentity({ accountId: 'acc-ZB', deviceId: 'dev-ZB' });
  identityC = await world.seedIdentity({ accountId: 'acc-ZC', deviceId: 'dev-ZC' });
  await world.conversation(CONV_AB, [identityA.accountId, identityB.accountId]);
  await world.conversation(CONV_B_PRIVATE, [identityB.accountId, identityC.accountId]);
});

after(async () => {
  await world.stop();
});

test("1. A cannot send into B's private conversation (FORBIDDEN)", async () => {
  const a = await world.connected(identityA, 'A');
  a.emitRaw('message.send', {
    message_id: 'msg-intruder',
    conversation_id: CONV_B_PRIVATE,
    ciphertext: Buffer.from('intruso').toString('base64'),
    header_type: 'dr.v1',
  });
  const error = (await a.next('system.error')) as Record<string, unknown>;
  assert.equal(error['code'], 'FORBIDDEN');
  assert.equal(error['event'], 'message.send');
  a.disconnect();
});

test("2. A cannot sync/read B's private conversation (FORBIDDEN)", async () => {
  const a = await world.connected(identityA, 'A');
  a.emitRaw('sync.request', { conversation_id: CONV_B_PRIVATE, last_seq: 0 });
  const error = (await a.next('system.error')) as Record<string, unknown>;
  assert.equal(error['code'], 'FORBIDDEN');
  assert.equal(error['event'], 'sync.request');
  a.disconnect();
});

test("3. A never receives fan-out from B's private conversation", async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');
  const c = await world.connected(identityC, 'C');

  await b.sendAndAwaitAck({
    conversationId: CONV_B_PRIVATE,
    ciphertextBase64: Buffer.from('privado B<->C').toString('base64'),
  });
  // C is a member and receives it; A must see nothing.
  const seen = (await c.next('message.new')) as Record<string, unknown>;
  assert.equal(seen['conversation_id'], CONV_B_PRIVATE);
  await a.expectNone('message.new', 300);

  a.disconnect();
  b.disconnect();
  c.disconnect();
});

test('4. A cannot join a room by asking for it (rooms are server-granted)', async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');

  // Every client-side "join"-ish attempt goes through an authorized event.
  for (const event of ['sync.request', 'message.typing', 'message.read']) {
    a.emitRaw(event, { conversation_id: CONV_B_PRIVATE });
    const error = (await a.next('system.error')) as Record<string, unknown>;
    assert.equal(error['code'], 'FORBIDDEN', `${event} must not grant a room`);
  }
  // And A still receives nothing from that room afterwards.
  await b.sendAndAwaitAck({
    conversationId: CONV_B_PRIVATE,
    ciphertextBase64: Buffer.from('sigue privado').toString('base64'),
  });
  await a.expectNone('message.new', 300);

  a.disconnect();
  b.disconnect();
});

test("5. A cannot send a message AS B (identity is server-stamped)", async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');

  // A sends into the SHARED conversation but claims to be B.
  a.emitRaw('message.send', {
    message_id: `msg-spoof-${Date.now()}`,
    conversation_id: CONV_AB,
    sender_account_id: identityB.accountId,
    sender_device_id: identityB.deviceId,
    ciphertext: Buffer.from('me hago pasar por B').toString('base64'),
    header_type: 'dr.v1',
  });
  // Using another device's id is refused outright.
  const error = (await a.next('system.error')) as Record<string, unknown>;
  assert.equal(error['code'], 'PAYLOAD_INVALID');

  // Without the device id, the server stamps the TRUE sender.
  const messageId = `msg-spoof2-${Date.now()}`;
  a.emitRaw('message.send', {
    message_id: messageId,
    conversation_id: CONV_AB,
    sender_account_id: identityB.accountId, // ignored claim
    ciphertext: Buffer.from('otro intento').toString('base64'),
    header_type: 'dr.v1',
  });
  await a.waitForAck(messageId);
  const inbound = (await b.next('message.new')) as Record<string, unknown>;
  assert.equal(
    inbound['sender_account_id'],
    identityA.accountId,
    'the server stamps the real sender, never the claim',
  );
  assert.equal(inbound['sender_device_id'], identityA.deviceId);

  a.disconnect();
  b.disconnect();
});

test("6. A cannot use B's Device ID (handshake rejects it)", async () => {
  const a = world.client(identityA, 'A-spoof');
  a.connect();
  await assert.rejects(
    () => a.authenticate({ deviceId: identityB.deviceId }),
    /auth.failure/,
    "A must not authenticate with B's device id",
  );
  a.disconnect();
});

test("7. A cannot use B's session id (authorization is socket-bound)", async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');
  const bSession = b.session!.session_id;

  // A names B's session on a privileged event. The server ignores the
  // claim entirely and authorizes by the session bound to A's socket.
  a.emitRaw('sync.request', {
    conversation_id: CONV_B_PRIVATE,
    last_seq: 0,
    session_id: bSession,
  });
  const error = (await a.next('system.error')) as Record<string, unknown>;
  assert.equal(error['code'], 'FORBIDDEN', 'a borrowed session id grants nothing');

  a.disconnect();
  b.disconnect();
});

test("8. A cannot mark B's messages read in a conversation it does not belong to", async () => {
  const a = await world.connected(identityA, 'A');
  a.emitRaw('message.read', { conversation_id: CONV_B_PRIVATE, last_read_seq: 1 });
  const error = (await a.next('system.error')) as Record<string, unknown>;
  assert.equal(error['code'], 'FORBIDDEN');
  a.disconnect();
});

test('9. a delivered receipt cannot invent a message', async () => {
  const a = await world.connected(identityA, 'A');
  a.emitRaw('message.delivered', {
    conversation_id: CONV_AB,
    message_id: 'msg-que-no-existe',
  });
  const error = (await a.next('system.error')) as Record<string, unknown>;
  assert.equal(error['code'], 'PAYLOAD_INVALID');
  a.disconnect();
});

test('10. revoking B\'s device does not disturb A', async () => {
  const doomed = await world.seedIdentity({ accountId: 'acc-doomed' });
  await world.conversation('conv-doomed', [identityA.accountId, doomed.accountId]);
  const a = await world.connected(identityA, 'A');
  const victim = await world.connected(doomed, 'victim');

  await world.server.adminRevokeDevice(doomed.deviceId);
  await victim.next('device.revoked');
  await victim.next('disconnect');
  assert.equal(victim.state, 'blocked');

  // A is untouched and can still work.
  await sleep(50);
  assert.equal(a.authenticated, true);
  const messageId = `msg-after-revoke-${Date.now()}`;
  a.sendEnvelope({
    conversationId: CONV_AB,
    ciphertextBase64: Buffer.from('sigo operando').toString('base64'),
    messageId,
  });
  const ack = await a.waitForAck(messageId);
  assert.equal(ack['message_id'], messageId);

  a.disconnect();
  victim.disconnect();
});

test('11. session revocation disconnects exactly that socket', async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');

  assert.equal(world.server.adminRevokeSession(a.session!.session_id), true);
  const error = (await a.next('system.error')) as Record<string, unknown>;
  assert.equal(error['code'], 'SESSION_EXPIRED');
  await a.next('disconnect');

  // B is unaffected.
  assert.equal(b.authenticated, true);
  b.updatePresence('online');
  await b.expectNone('system.error', 200);

  a.disconnect();
  b.disconnect();
});

test('12. session ids are unpredictable (no counters, no reuse)', async () => {
  const seen = new Set<string>();
  for (let i = 0; i < 6; i += 1) {
    const identity = await world.seedIdentity();
    const client = await world.connected(identity);
    const id = client.session!.session_id;
    assert.ok(id.length >= 32, 'session ids carry real entropy');
    assert.equal(seen.has(id), false, 'session ids never repeat');
    seen.add(id);
    client.disconnect();
  }
});
