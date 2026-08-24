/**
 * E2E — Messaging: message.send / ack / new / delivered / read.
 *
 * The server only ever sees opaque E2EE ciphertext; ordering authority is
 * the server-assigned server_seq; sends are idempotent by message_id
 * (retries converge to the ORIGINAL ack); membership is enforced
 * server-side for both sending and receiving. Parity with
 * test/socket/message_idempotency_test.dart + authorization_test.dart.
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { RealtimeServer } from '../src/realtime_server.js';
import { TestWorld, seedConversation, seedUser } from './helpers.js';

const world = new TestWorld(() => new RealtimeServer());

const CONV = 'conv-main';
let alice: Awaited<ReturnType<typeof seedUser>>;
let bob: Awaited<ReturnType<typeof seedUser>>;

before(async () => {
  await world.start();
  alice = await seedUser(world.server, { accountId: 'acc-alice' });
  bob = await seedUser(world.server, { accountId: 'acc-bob' });
  await seedConversation(world.server, CONV, [alice.accountId, bob.accountId]);
});

after(async () => {
  await world.stop();
});

test('1. send: ack to the emitter, fan-out to members, ciphertext stored opaque', async () => {
  const a = world.client();
  const b = world.client();
  await a.authenticate(alice);
  await b.authenticate(bob);

  const ciphertext = Buffer.from('e2ee-ciphertext-opaque').toString('base64');
  const { messageId, ack } = await a.sendMessage({
    conversationId: CONV,
    identity: alice,
    ciphertextBase64: ciphertext,
  });
  assert.ok(ack.server_seq >= 1, 'server_seq assigned');
  assert.equal(ack.message_id, messageId);

  const fanout = (await b.next('message.new')) as Record<string, unknown>;
  assert.equal(fanout['message_id'], messageId);
  assert.equal(fanout['ciphertext'], ciphertext, 'ciphertext relayed verbatim');
  assert.equal(fanout['header_type'], 'dr.v1');
  assert.equal(fanout['sender_device_id'], alice.deviceId);
  assert.equal(fanout['server_seq'], ack.server_seq, 'same seq in ack and fan-out');
  assert.ok(typeof fanout['received_at_ms'] === 'number');

  // Server-side persistence: ciphertext verbatim + metadata only.
  const stored = (world.server.store as { allMessages(): Array<Record<string, unknown>> })
    .allMessages()
    .find((message) => message['messageId'] === messageId);
  assert.ok(stored, 'message persisted');
  assert.equal(stored!['ciphertextBase64'], ciphertext);
  assert.equal(stored!['serverSeq'], ack.server_seq);
  a.disconnect();
  b.disconnect();
});

test('2. server_seq is strictly monotonic per conversation', async () => {
  const a = world.client();
  await a.authenticate(alice);
  const seqs: number[] = [];
  for (let i = 0; i < 3; i++) {
    const { ack } = await a.sendMessage({ conversationId: CONV, identity: alice });
    seqs.push(ack.server_seq);
  }
  assert.ok(seqs[1] > seqs[0], `seq increases: ${seqs.join(',')}`);
  assert.ok(seqs[2] > seqs[1], `seq increases: ${seqs.join(',')}`);
  a.disconnect();
});

test('3. retry with the same message_id is idempotent (original ack, one fan-out)', async () => {
  const a = world.client();
  const b = world.client();
  await a.authenticate(alice);
  await b.authenticate(bob);
  const newEvents = b.collect('message.new');

  const messageId = `msg-idem-${Math.random().toString(36).slice(2)}`;
  const first = await a.sendMessage({ conversationId: CONV, identity: alice, messageId });
  const firstFanout = (await b.next('message.new')) as Record<string, unknown>; // drain the legit one
  assert.equal(firstFanout['message_id'], messageId);
  const second = await a.sendMessage({ conversationId: CONV, identity: alice, messageId });

  assert.equal(second.ack.server_seq, first.ack.server_seq, 'retry gets the ORIGINAL seq');
  assert.equal((second.ack as { duplicate?: boolean }).duplicate, true);
  await b.expectNone('message.new', 250); // no second fan-out
  assert.equal(newEvents.count(), 1, 'exactly one message.new for the recipient');
  newEvents.stop();
  a.disconnect();
  b.disconnect();
});

test('4. non-member cannot send (FORBIDDEN)', async () => {
  const outsider = await seedUser(world.server, { accountId: 'acc-outsider' });
  const o = world.client();
  await o.authenticate(outsider);
  const messageId = 'msg-forbidden';
  o.emit('message.send', {
    message_id: messageId,
    conversation_id: CONV,
    sender_device_id: outsider.deviceId,
    ciphertext: Buffer.from('x').toString('base64'),
    header_type: 'dr.v1',
  });
  const error = await o.next('system.error');
  assert.equal((error as { code: string }).code, 'FORBIDDEN');
  assert.equal((error as { message_id: string }).message_id, messageId);
  o.disconnect();
});

test('5. fan-out reaches members only', async () => {
  const outsider = await seedUser(world.server, { accountId: 'acc-lurker' });
  const a = world.client();
  const o = world.client();
  await a.authenticate(alice);
  await o.authenticate(outsider);
  await a.sendMessage({ conversationId: CONV, identity: alice });
  await o.expectNone('message.new', 250);
  a.disconnect();
  o.disconnect();
});

test('6. invalid envelope (missing ciphertext) -> PAYLOAD_INVALID', async () => {
  const a = world.client();
  await a.authenticate(alice);
  a.emit('message.send', {
    message_id: 'msg-no-ct',
    conversation_id: CONV,
    header_type: 'dr.v1',
  });
  const error = await a.next('system.error');
  assert.equal((error as { code: string }).code, 'PAYLOAD_INVALID');
  a.disconnect();
});

test('7. envelope carrying a plaintext-ish key -> PAYLOAD_INVALID', async () => {
  const a = world.client();
  await a.authenticate(alice);
  a.emit('message.send', {
    message_id: 'msg-plaintext-guard',
    conversation_id: CONV,
    sender_device_id: alice.deviceId,
    ciphertext: Buffer.from('x').toString('base64'),
    header_type: 'dr.v1',
    text: 'hola mundo en claro', // forbidden plaintext-ish key
  });
  const error = await a.next('system.error');
  assert.equal((error as { code: string }).code, 'PAYLOAD_INVALID');
  assert.equal((error as { message_id: string }).message_id, 'msg-plaintext-guard');
  a.disconnect();
});

test('8. oversized ciphertext -> PAYLOAD_INVALID', async () => {
  const a = world.client();
  await a.authenticate(alice);
  const max = world.server.config.maxCiphertextBase64Chars;
  a.emit('message.send', {
    message_id: 'msg-huge',
    conversation_id: CONV,
    ciphertext: 'A'.repeat(max + 1),
    header_type: 'dr.v1',
  });
  const error = await a.next('system.error');
  assert.equal((error as { code: string }).code, 'PAYLOAD_INVALID');
  a.disconnect();
});

test('9. spoofed sender_device_id -> PAYLOAD_INVALID', async () => {
  const a = world.client();
  await a.authenticate(alice);
  a.emit('message.send', {
    message_id: 'msg-spoof',
    conversation_id: CONV,
    sender_device_id: bob.deviceId, // claims to be Bob's device
    ciphertext: Buffer.from('x').toString('base64'),
    header_type: 'dr.v1',
  });
  const error = await a.next('system.error');
  assert.equal((error as { code: string }).code, 'PAYLOAD_INVALID');
  a.disconnect();
});

test('10. delivered and read receipts relay to the conversation', async () => {
  const a = world.client();
  const b = world.client();
  await a.authenticate(alice);
  await b.authenticate(bob);
  const { messageId } = await a.sendMessage({ conversationId: CONV, identity: alice });

  b.emit('message.delivered', { conversation_id: CONV, message_id: messageId });
  const delivered = (await a.next('message.delivered')) as Record<string, unknown>;
  assert.equal(delivered['message_id'], messageId);
  assert.equal(delivered['by_account_id'], bob.accountId);
  assert.equal(delivered['by_device_id'], bob.deviceId);

  b.emit('message.read', { conversation_id: CONV });
  const read = (await a.next('message.read')) as Record<string, unknown>;
  assert.equal(read['conversation_id'], CONV);
  assert.equal(read['by_account_id'], bob.accountId);
  a.disconnect();
  b.disconnect();
});
