/**
 * FASE 1 — E2E: security attack matrix (§38).
 *
 * §38 lists attacks that must ALL fail correctly. This suite performs
 * them against the real server and asserts the rejection, rather than
 * asserting the happy path and hoping.
 *
 * The AAD-level attacks (tampering with conversation/sender/message ids
 * so the ciphertext decrypts in a forged context) are covered by the Dart
 * test `test/messaging/message_aad_test.dart`, because that binding is
 * enforced client-side on decrypt — the server, by design, cannot verify
 * it: it never holds the key.
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { World } from './world.js';
import type { NovaIdentity } from '../src/client/nova_client.js';

const CONV_AB = 'conv-sec-ab';
const CONV_PRIVATE = 'conv-sec-private';
const world = new World();

let alice: NovaIdentity;
let bob: NovaIdentity;
let mallory: NovaIdentity;

before(async () => {
  await world.start();
  alice = await world.seedIdentity({ accountId: 'acc-SEC-A', deviceId: 'dev-SEC-A' });
  bob = await world.seedIdentity({ accountId: 'acc-SEC-B', deviceId: 'dev-SEC-B' });
  mallory = await world.seedIdentity({ accountId: 'acc-SEC-M', deviceId: 'dev-SEC-M' });
  await world.conversation(CONV_AB, [alice.accountId, bob.accountId]);
  await world.conversation(CONV_PRIVATE, [bob.accountId]);
});

after(async () => {
  await world.stop();
});

test('1. altering sender_id is refused (identity is server-stamped)', async () => {
  // Membership must exist BEFORE either side authenticates: rooms are
  // granted at handshake time from server-side truth.
  await world.conversation('conv-sec-mb', [mallory.accountId, bob.accountId]);
  const m = await world.connected(mallory, 'M');
  const b = await world.connected(bob, 'B');

  const messageId = `msg-fake-sender-${Date.now()}`;
  m.emitRaw('message.send', {
    message_id: messageId,
    conversation_id: 'conv-sec-mb',
    sender_account_id: alice.accountId, // claiming to be Alice
    ciphertext: Buffer.from('forged').toString('base64'),
    header_type: 'dr.v1',
  });
  await m.waitForAck(messageId);

  const inbound = (await b.next('message.new')) as Record<string, unknown>;
  assert.equal(
    inbound['sender_account_id'],
    mallory.accountId,
    'the server stamps the REAL sender, ignoring the claim',
  );
  m.disconnect();
  b.disconnect();
});

test('2. altering conversation_id to a foreign chat is FORBIDDEN', async () => {
  const m = await world.connected(mallory, 'M');
  m.emitRaw('message.send', {
    message_id: `msg-wrong-conv-${Date.now()}`,
    conversation_id: CONV_PRIVATE, // Mallory is not a member
    ciphertext: Buffer.from('x').toString('base64'),
    header_type: 'dr.v1',
  });
  const error = (await m.next('system.error')) as Record<string, unknown>;
  assert.equal(error['code'], 'FORBIDDEN');
  m.disconnect();
});

test('3. reading a foreign conversation is FORBIDDEN', async () => {
  const m = await world.connected(mallory, 'M');
  m.emitRaw('sync.request', { conversation_id: CONV_PRIVATE, last_seq: 0 });
  const error = (await m.next('system.error')) as Record<string, unknown>;
  assert.equal(error['code'], 'FORBIDDEN');
  m.disconnect();
});

test('4. replaying a captured envelope is idempotent, never a second message', async () => {
  const a = await world.connected(alice, 'A');
  const b = await world.connected(bob, 'B');

  const messageId = `msg-replay-${Date.now()}`;
  const envelope = {
    message_id: messageId,
    conversation_id: CONV_AB,
    recipient_device_id: bob.deviceId,
    ciphertext: Buffer.from('replay-me').toString('base64'),
    header_type: 'dr.v1',
  };

  a.emitRaw('message.send', envelope);
  await a.waitForAck(messageId);
  await b.next('message.new');

  // Replay the byte-identical envelope three times.
  for (let i = 0; i < 3; i += 1) {
    a.emitRaw('message.send', envelope);
    const ack = await a.waitForAck(messageId);
    assert.equal(ack['duplicate'], true, 'every replay is absorbed');
  }
  await b.expectNone('message.new', 400);

  a.disconnect();
  b.disconnect();
});

test('5. a modified ciphertext still cannot forge membership', async () => {
  // The server cannot verify ciphertext (it holds no keys) — that is the
  // client's job via the AAD. What it MUST do is keep enforcing authz
  // regardless of what the ciphertext contains.
  const m = await world.connected(mallory, 'M');
  m.emitRaw('message.send', {
    message_id: `msg-tampered-${Date.now()}`,
    conversation_id: CONV_AB, // Alice+Bob only
    ciphertext: Buffer.from('tampered').toString('base64'),
    header_type: 'dr.v1',
  });
  const error = (await m.next('system.error')) as Record<string, unknown>;
  assert.equal(error['code'], 'FORBIDDEN');
  m.disconnect();
});

test('6. cursor manipulation cannot reveal a foreign conversation', async () => {
  const m = await world.connected(mallory, 'M');
  for (const cursor of [-1, 0, 999999, Number.MAX_SAFE_INTEGER]) {
    m.emitRaw('sync.request', { conversation_id: CONV_PRIVATE, last_seq: cursor });
    const error = (await m.next('system.error')) as Record<string, unknown>;
    assert.equal(error['code'], 'FORBIDDEN', `cursor ${cursor} must not bypass authz`);
  }
  m.disconnect();
});

test('7. an account-wide sync only ever returns own conversations', async () => {
  const m = await world.connected(mallory, 'M');
  const response = await m.sync();
  const conversations = (response['conversations'] as Array<Record<string, unknown>>) ?? [];
  const ids = conversations.map((entry) => entry['conversation_id']);
  assert.equal(
    ids.includes(CONV_PRIVATE),
    false,
    'a foreign conversation must never leak into an account-wide sync',
  );
  assert.equal(ids.includes(CONV_AB), false);
  m.disconnect();
});

test('8. a client cannot skip the server sequence', async () => {
  const a = await world.connected(alice, 'A');
  const messageId = `msg-seq-${Date.now()}`;
  a.emitRaw('message.send', {
    message_id: messageId,
    conversation_id: CONV_AB,
    server_seq: 999999, // client tries to dictate its position
    ciphertext: Buffer.from('seq').toString('base64'),
    header_type: 'dr.v1',
  });
  const ack = await a.waitForAck(messageId);
  assert.notEqual(ack['server_seq'], 999999, 'the server assigns the sequence itself');
  assert.ok((ack['server_seq'] as number) < 1000, 'sequence follows the real counter');
  a.disconnect();
});

test('9. a client-supplied received_at cannot rewrite server time', async () => {
  const a = await world.connected(alice, 'A');
  const b = await world.connected(bob, 'B');
  const messageId = `msg-time-${Date.now()}`;
  const before = Date.now();

  a.emitRaw('message.send', {
    message_id: messageId,
    conversation_id: CONV_AB,
    recipient_device_id: bob.deviceId,
    received_at_ms: 0, // forged
    client_ts_ms: 1,
    ciphertext: Buffer.from('time').toString('base64'),
    header_type: 'dr.v1',
  });
  await a.waitForAck(messageId);

  const inbound = (await b.next('message.new')) as Record<string, unknown>;
  assert.ok(
    (inbound['received_at_ms'] as number) >= before,
    'received_at is stamped by the server, not by the client',
  );
  a.disconnect();
  b.disconnect();
});

test('10. an oversized ciphertext is rejected (upload-bypass attempt)', async () => {
  const a = await world.connected(alice, 'A');
  // §23: big files must go through encrypted object storage, never the
  // socket. The cap is what enforces it.
  const oversized = 'A'.repeat(world.server.config.maxCiphertextBase64Chars + 1000);
  a.emitRaw('message.send', {
    message_id: `msg-huge-${Date.now()}`,
    conversation_id: CONV_AB,
    ciphertext: oversized,
    header_type: 'dr.v1',
  });
  const error = (await a.next('system.error')) as Record<string, unknown>;
  assert.equal(error['code'], 'PAYLOAD_INVALID');
  a.disconnect();
});

test('11. plaintext-looking fields are refused on the send path', async () => {
  const a = await world.connected(alice, 'A');
  for (const key of ['plaintext', 'text', 'content', 'body', 'message', 'decrypted']) {
    a.emitRaw('message.send', {
      message_id: `msg-pt-${key}-${Date.now()}`,
      conversation_id: CONV_AB,
      ciphertext: Buffer.from('ct').toString('base64'),
      header_type: 'dr.v1',
      [key]: 'contenido en claro',
    });
    const error = (await a.next('system.error')) as Record<string, unknown>;
    assert.equal(error['code'], 'PAYLOAD_INVALID', `'${key}' must be refused`);
  }
  a.disconnect();
});

test('12. a receipt cannot be forged for a message that does not exist', async () => {
  const a = await world.connected(alice, 'A');
  a.emitRaw('message.delivered', {
    conversation_id: CONV_AB,
    message_id: 'msg-never-existed',
  });
  const error = (await a.next('system.error')) as Record<string, unknown>;
  assert.equal(error['code'], 'PAYLOAD_INVALID');
  a.disconnect();
});

test('13. an unauthenticated socket can do nothing at all', async () => {
  const client = world.client(mallory, 'M-raw');
  client.connect();
  await client.next('connect');
  await client.nextChallenge();

  for (const event of ['message.send', 'sync.request', 'presence.update', 'call.offer']) {
    const probe = world.client(mallory, `probe-${event}`);
    probe.connect();
    await probe.next('connect');
    await probe.nextChallenge();
    probe.emitRaw(event, { conversation_id: CONV_AB, peer_account_id: bob.accountId });
    const error = (await probe.next('system.error')) as Record<string, unknown>;
    assert.equal(error['code'], 'FORBIDDEN', `${event} must require authentication`);
    probe.disconnect();
  }
  client.disconnect();
});
