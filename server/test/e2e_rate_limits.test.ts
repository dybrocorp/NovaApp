/**
 * E2E — Server-side rate limits (token bucket per domain, per socket).
 *
 * Same values as the client presets (SocketRateLimitPresets): 30 msg/min,
 * 12 typing/min, 6 sync/min, 5 auth/min + lockout after 5 failures. An
 * honest client stays under them; only abuse trips them. The IP-lockout
 * case runs last on purpose: after it, the shared loopback IP scope stays
 * locked for the remainder of the suite (own server instance).
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { RealtimeServer } from '../src/realtime_server.js';
import { AuthError, TestWorld, seedConversation, seedUser } from './helpers.js';

const world = new TestWorld(() => new RealtimeServer());

const CONV = 'conv-rl';
let sender: Awaited<ReturnType<typeof seedUser>>;

before(async () => {
  await world.start();
  sender = await seedUser(world.server, { accountId: 'acc-rl' });
  await seedConversation(world.server, CONV, [sender.accountId]);
});

after(async () => {
  await world.stop();
});

test('1. message.send burst is capped at 30/min (31st -> RATE_LIMITED)', async () => {
  const client = world.client();
  await client.authenticate(sender);
  const errors = client.collect('system.error');

  for (let i = 0; i < 31; i++) {
    client.emit('message.send', {
      message_id: `msg-rl-${i}`,
      conversation_id: CONV,
      sender_device_id: sender.deviceId,
      ciphertext: Buffer.from(`ct-${i}`).toString('base64'),
      header_type: 'dr.v1',
    });
  }
  // All 30 accepted acks + exactly one rejection for the 31st.
  for (let i = 0; i < 30; i++) {
    await client.next('message.ack');
  }
  const limited = (await client.next('system.error')) as Record<string, unknown>;
  assert.equal(limited['code'], 'RATE_LIMITED');
  assert.equal(limited['message_id'], 'msg-rl-30');
  await client.expectNone('system.error', 250); // nothing else rejected
  assert.equal(errors.count(), 1);
  errors.stop();
  client.disconnect();
});

test('2. typing burst is capped at 12/min (13th -> RATE_LIMITED)', async () => {
  const client = world.client();
  await client.authenticate(sender);
  for (let i = 0; i < 12; i++) {
    client.emit('message.typing', { conversation_id: CONV });
  }
  client.emit('message.typing', { conversation_id: CONV }); // the 13th
  const limited = (await client.next('system.error')) as Record<string, unknown>;
  assert.equal(limited['code'], 'RATE_LIMITED');
  assert.equal(limited['event'], 'message.typing');
  client.disconnect();
});

test('3. sync.request burst is capped at 6/min (7th -> RATE_LIMITED)', async () => {
  const client = world.client();
  await client.authenticate(sender);
  for (let i = 0; i < 6; i++) {
    client.emit('sync.request', { conversation_id: CONV, last_seq: 0 });
    await client.next('sync.response');
  }
  client.emit('sync.request', { conversation_id: CONV, last_seq: 0 });
  const limited = (await client.next('system.error')) as Record<string, unknown>;
  assert.equal(limited['code'], 'RATE_LIMITED');
  assert.equal(limited['event'], 'sync.request');
  client.disconnect();
});

test('4. auth failures lock the IP out (RATE_LIMITED, runs last by design)', async () => {
  // Five failed handshakes from five DIFFERENT devices (no device-scope
  // lockout) but the same loopback IP.
  for (let i = 0; i < 5; i++) {
    const identity = await seedUser(world.server);
    const client = world.client();
    await assert.rejects(
      () =>
        client.authenticate(identity, {
          signatureBase64: Buffer.from('bad-signature').toString('base64'),
        }),
      (error: unknown) => error instanceof AuthError && error.code === 'AUTH_FAILED',
    );
    client.disconnect();
  }

  // Sixth connection: perfectly valid credentials from the same IP — the
  // honest client must be told to back off (RATE_LIMITED, not AUTH_FAILED).
  const honest = await seedUser(world.server);
  const client = world.client();
  await assert.rejects(
    () => client.authenticate(honest),
    (error: unknown) => error instanceof AuthError && error.code === 'RATE_LIMITED',
  );
  client.disconnect();
});
