/**
 * E2E — Sessions & device lifecycle.
 *
 * One live session per device, sliding TTL, revocation of sessions and
 * devices (fan-out of device.revoked + socket kills), and the "no events
 * before auth.success" hard rule. Parity with
 * test/socket/session_registry_test.dart, device_revocation_test.dart and
 * authorization_test.dart (PASO 4).
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { RealtimeServer } from '../src/realtime_server.js';
import { AuthError, TestClient, TestWorld, seedUser } from './helpers.js';

const world = new TestWorld(() => new RealtimeServer());

before(async () => {
  await world.start();
});

after(async () => {
  await world.stop();
});

test('1. events before auth.success are rejected (FORBIDDEN + disconnect)', async () => {
  const client = world.client();
  await client.ready();
  await client.challenge(); // handshake not completed
  client.emit('message.send', {
    message_id: 'msg-early',
    conversation_id: 'conv-early',
    ciphertext: Buffer.from('x').toString('base64'),
    header_type: 'dr.v1',
  });
  const error = await client.next('system.error');
  assert.equal((error as { code: string }).code, 'FORBIDDEN');
  assert.equal((error as { event: string }).event, 'message.send');
  await client.onDisconnect();
  client.disconnect();
});

test('2. one live session per device: a new handshake evicts the old socket', async () => {
  const identity = await seedUser(world.server);
  const first = world.client();
  const firstSuccess = await first.authenticate(identity);
  assert.ok(first.isConnected);

  // Same device reconnects elsewhere -> previous session dies.
  const second = world.client();
  await second.authenticate(identity);

  const error = await first.next('system.error');
  assert.equal((error as { code: string }).code, 'SESSION_EXPIRED');
  await first.onDisconnect();

  const validation = world.server.sessions.validate(
    firstSuccess.session_id,
    'whatever-socket',
  );
  assert.notEqual(validation, 'ok', 'evicted session can never validate again');
  assert.equal(world.server.sessions.deviceHasLiveSession(identity.deviceId), true);
  second.disconnect();
});

test('3. admin session revocation kills exactly that socket', async () => {
  const identity = await seedUser(world.server);
  const client = world.client();
  const success = await client.authenticate(identity);

  assert.equal(world.server.adminRevokeSession(success.session_id), true);
  const error = await client.next('system.error');
  assert.equal((error as { code: string }).code, 'SESSION_EXPIRED');
  await client.onDisconnect();
  assert.equal(world.server.sessions.bySessionId(success.session_id), null);
  client.disconnect();
});

test('4. device revocation: fan-out device.revoked, kill sessions, block re-auth', async () => {
  const identity = await seedUser(world.server);
  const client = world.client();
  const success = await client.authenticate(identity);

  const result = await world.server.adminRevokeDevice(identity.deviceId);
  assert.equal(result.revoked, true);
  assert.equal(result.sessionsKilled, 1);

  const revoked = await client.next('device.revoked');
  assert.equal((revoked as { device_id: string }).device_id, identity.deviceId);
  await client.onDisconnect();

  assert.equal(world.server.sessions.bySessionId(success.session_id), null);
  assert.equal(world.server.sessions.deviceHasLiveSession(identity.deviceId), false);

  // A revoked device can never complete a handshake again.
  const retry = world.client();
  await assert.rejects(
    () => retry.authenticate(identity),
    (error: unknown) => error instanceof AuthError && error.code === 'AUTH_FAILED',
  );
  retry.disconnect();
});

test('5. expired session rejects the next event (SESSION_EXPIRED)', async () => {
  const shortTtl = new RealtimeServer({ config: { sessionTtlMs: 250 } });
  const port = await shortTtl.start();
  try {
    const identity = await seedUser(shortTtl);
    await shortTtl.adminAddConversationMember('conv-ttl', identity.accountId);
    const client = TestClient.connect(port);
    await client.authenticate(identity);
    await new Promise((resolve) => setTimeout(resolve, 350)); // session expires
    client.emit('sync.request', { conversation_id: 'conv-ttl', last_seq: 0 });
    const error = await client.next('system.error');
    assert.equal((error as { code: string }).code, 'SESSION_EXPIRED');
    await client.onDisconnect();
    client.disconnect();
  } finally {
    await shortTtl.stop();
  }
});

test('6. session TTL renews on activity (sliding window)', async () => {
  const sliding = new RealtimeServer({ config: { sessionTtlMs: 600 } });
  const port = await sliding.start();
  try {
    const identity = await seedUser(sliding);
    await sliding.adminAddConversationMember('conv-slide', identity.accountId);
    const client = TestClient.connect(port);
    await client.authenticate(identity);

    const sync = async () => {
      client.emit('sync.request', { conversation_id: 'conv-slide', last_seq: 0 });
      await client.next('sync.response');
    };

    await sync(); // t=0: activity
    await new Promise((resolve) => setTimeout(resolve, 350));
    await sync(); // t=350ms: renewed -> expiry is now t=950ms
    await new Promise((resolve) => setTimeout(resolve, 350)); // t=700ms > original TTL
    await sync(); // still alive because the window slides on activity
    client.disconnect();
  } finally {
    await sliding.stop();
  }
});
