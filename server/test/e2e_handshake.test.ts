/**
 * E2E — Handshake (auth.challenge / auth.response / auth.success).
 *
 * Exercises the REAL server over loopback WebSockets with real Ed25519
 * signatures. Parity with test/socket/auth_protocol_test.dart (PASO 4):
 * the same verification sequence, the same generic AUTH_FAILED on the
 * wire for every rejection (no enumeration oracle).
 *
 * NOTE: this suite runs its server with the 'device' lockout scope only,
 * so repeated failures across cases cannot poison the shared loopback IP.
 * The 'ip' scope is covered in e2e_rate_limits.test.ts (own server).
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { RealtimeServer } from '../src/realtime_server.js';
import {
  AuthError,
  TestWorld,
  makeIdentity,
  registerIdentity,
  signCanonical,
} from './helpers.js';

const world = new TestWorld(
  () =>
    new RealtimeServer({
      config: { authLockoutScopes: ['device'] },
    }),
);

before(async () => {
  await world.start();
});

after(async () => {
  await world.stop();
});

test('1. connection emits a well-formed auth.challenge', async () => {
  const client = world.client();
  await client.ready();
  const challenge = await client.challenge();
  assert.equal(typeof challenge.challenge_id, 'string');
  assert.ok(challenge.challenge_id.length > 0);
  const bytes = Buffer.from(challenge.challenge, 'base64');
  assert.ok(bytes.length >= 32, 'challenge carries >= 32 bytes of entropy');
  const now = Date.now();
  assert.ok(challenge.expires_at_ms > now, 'challenge not already expired');
  assert.ok(
    challenge.expires_at_ms <= now + 10 * 60 * 1000,
    'challenge expiry is plausible (<= 10 min)',
  );
  client.disconnect();
});

test('2. successful handshake returns auth.success bound to the identity', async () => {
  const identity = makeIdentity();
  await registerIdentity(world.server, identity);
  const client = world.client();
  const success = await client.authenticate(identity);
  assert.ok(success.session_id.length > 0, 'opaque session id');
  assert.equal(success.account_id, identity.accountId);
  assert.equal(success.device_id, identity.deviceId);
  assert.equal(success.nova_id, identity.novaId);
  // Session TTL is 24h by default.
  assert.ok(success.expires_at_ms > Date.now() + 23 * 60 * 60 * 1000);
  assert.equal(world.server.sessions.liveCount, 1);
  client.disconnect();
});

test('3. malformed payload -> AUTH_FAILED + disconnect', async () => {
  const identity = makeIdentity();
  await registerIdentity(world.server, identity);
  const client = world.client();
  await client.ready();
  const challenge = await client.challenge();
  // Emit a payload missing the signature entirely.
  client.emit('auth.response', {
    challenge_id: challenge.challenge_id,
    account_id: identity.accountId,
    device_id: identity.deviceId,
    nova_id: identity.novaId,
    ts_ms: Date.now(),
  });
  const failure = await client.next('auth.failure');
  assert.equal((failure as { code: string }).code, 'AUTH_FAILED');
  await client.onDisconnect();
  assert.equal(
    world.server.sessions.deviceHasLiveSession(identity.deviceId),
    false,
    'no session created',
  );
  client.disconnect();
});

test('4. unknown device -> generic AUTH_FAILED (no enumeration)', async () => {
  const client = world.client();
  await assert.rejects(
    () => client.authenticate(makeIdentity()), // never registered
    (error: unknown) => error instanceof AuthError && error.code === 'AUTH_FAILED',
  );
  client.disconnect();
});

test('5. revoked device -> AUTH_FAILED on the wire', async () => {
  const identity = makeIdentity();
  await registerIdentity(world.server, identity);
  await world.server.adminRevokeDevice(identity.deviceId);
  const client = world.client();
  await assert.rejects(
    () => client.authenticate(identity),
    (error: unknown) => error instanceof AuthError && error.code === 'AUTH_FAILED',
  );
  assert.equal(
    world.server.sessions.deviceHasLiveSession(identity.deviceId),
    false,
    'revoked device gets no session',
  );
  client.disconnect();
});

test('6. nova_id not matching the registered device -> AUTH_FAILED', async () => {
  const identity = makeIdentity();
  await registerIdentity(world.server, identity);
  const client = world.client();
  await assert.rejects(
    () =>
      client.authenticate(identity, {
        novaId: 'NOVA-SOMEONE-ELSE', // signed consistently — still rejected
      }),
    (error: unknown) => error instanceof AuthError && error.code === 'AUTH_FAILED',
  );
  client.disconnect();
});

test('7. challenge is single-use: burned even by a failed attempt', async () => {
  const identity = makeIdentity();
  await registerIdentity(world.server, identity);
  const client = world.client();
  await client.ready();
  const challenge = await client.challenge();
  // Two responses in the same tick: first with a garbage signature, then a
  // fully valid one for the SAME challenge. The first failure burns the
  // challenge, so the second must fail too (anti-replay).
  const goodSignature = signCanonical(identity, challenge);
  client.emit('auth.response', {
    challenge_id: challenge.challenge_id,
    signature: Buffer.from('not-a-signature').toString('base64'),
    account_id: identity.accountId,
    device_id: identity.deviceId,
    nova_id: identity.novaId,
    ts_ms: Date.now(),
  });
  client.emit('auth.response', {
    challenge_id: challenge.challenge_id,
    signature: goodSignature,
    account_id: identity.accountId,
    device_id: identity.deviceId,
    nova_id: identity.novaId,
    ts_ms: Date.now(),
  });
  const first = await client.next('auth.failure');
  const second = await client.next('auth.failure');
  assert.equal((first as { code: string }).code, 'AUTH_FAILED');
  assert.equal((second as { code: string }).code, 'AUTH_FAILED');
  assert.equal(
    world.server.sessions.deviceHasLiveSession(identity.deviceId),
    false,
    'no session from a replayed challenge',
  );
  client.disconnect();
});

test('8. challenge is bound to the issuing socket', async () => {
  const identity = makeIdentity();
  await registerIdentity(world.server, identity);
  const honest = world.client();
  await honest.ready();
  const stolenChallenge = await honest.challenge(); // issued to socket A

  // Socket B replays A's challenge with a perfectly valid signature.
  const attacker = world.client();
  await attacker.ready();
  await attacker.challenge(); // consume own challenge event
  attacker.emit('auth.response', {
    challenge_id: stolenChallenge.challenge_id,
    signature: signCanonical(identity, stolenChallenge),
    account_id: identity.accountId,
    device_id: identity.deviceId,
    nova_id: identity.novaId,
    ts_ms: Date.now(),
  });
  const failure = await attacker.next('auth.failure');
  assert.equal((failure as { code: string }).code, 'AUTH_FAILED');
  assert.equal(world.server.sessions.deviceHasLiveSession(identity.deviceId), false);
  honest.disconnect();
  attacker.disconnect();
});

test('9. signature by a non-registered key -> AUTH_FAILED', async () => {
  const identity = makeIdentity();
  const stranger = makeIdentity();
  await registerIdentity(world.server, identity);
  const client = world.client();
  await assert.rejects(
    () => client.authenticate(identity, { signingKey: stranger.privateKey }),
    (error: unknown) => error instanceof AuthError && error.code === 'AUTH_FAILED',
  );
  client.disconnect();
});

test('10. five failures lock the device out (RATE_LIMITED)', async () => {
  const identity = makeIdentity();
  await registerIdentity(world.server, identity);

  for (let attempt = 0; attempt < 5; attempt++) {
    const client = world.client();
    await assert.rejects(
      () => client.authenticate(identity, { signatureBase64: Buffer.from('bad').toString('base64') }),
      (error: unknown) => error instanceof AuthError && error.code === 'AUTH_FAILED',
    );
    client.disconnect();
  }

  // 6th attempt: valid credentials, but the device is locked out — and the
  // lockout is reported honestly so the client backs off.
  const lockedClient = world.client();
  await assert.rejects(
    () => lockedClient.authenticate(identity),
    (error: unknown) => error instanceof AuthError && error.code === 'RATE_LIMITED',
  );
  lockedClient.disconnect();
});
