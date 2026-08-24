/**
 * FASE 0.5 — E2E: authentication matrix (§4).
 *
 * Valid handshakes for A and B, and every listed attack path:
 * invalid signature, expired challenge, reused challenge, modified
 * challenge, wrong Device ID / Account ID / Nova ID, revoked device and
 * expired session. All of them MUST fail, and all cryptographic
 * rejections must answer the SAME generic code (no enumeration oracle).
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { World, sleep } from './world.js';
import { AuthFailed, createIdentity, NovaClient } from '../src/client/nova_client.js';
import { RealtimeServer } from '../src/realtime_server.js';

// Lockout scoped to 'device' only: repeated negative cases in this suite
// share the loopback IP and must not poison each other.
const world = new World({ config: { authLockoutScopes: ['device'] } });

before(async () => {
  await world.start();
});

after(async () => {
  await world.stop();
});

/** Runs a handshake attempt and returns the failure code (or 'SUCCESS'). */
async function attempt(run: () => Promise<unknown>): Promise<string> {
  try {
    await run();
    return 'SUCCESS';
  } catch (error) {
    if (error instanceof AuthFailed) return error.code;
    throw error;
  }
}

test('1. valid authentication — A completes the full handshake', async () => {
  const identity = await world.seedIdentity({ accountId: 'acc-auth-A' });
  const client = world.client(identity, 'A');
  client.connect();
  const success = await client.authenticate();

  assert.ok(success.session_id.length >= 20, 'opaque, high-entropy session id');
  assert.equal(success.account_id, identity.accountId);
  assert.equal(success.device_id, identity.deviceId);
  assert.equal(success.nova_id, identity.novaId);
  assert.ok(success.expires_at_ms > Date.now(), 'session carries an expiry');
  assert.equal(client.authenticated, true);
  client.disconnect();
});

test('2. valid authentication — B completes the same handshake independently', async () => {
  const identity = await world.seedIdentity({ accountId: 'acc-auth-B' });
  const client = world.client(identity, 'B');
  client.connect();
  const success = await client.authenticate();
  assert.equal(success.account_id, identity.accountId);
  client.disconnect();
});

test('3. the challenge is fresh, high-entropy and time-bounded', async () => {
  const identity = await world.seedIdentity();
  const first = world.client(identity);
  first.connect();
  const c1 = await first.nextChallenge();
  const second = world.client(identity);
  second.connect();
  const c2 = await second.nextChallenge();

  assert.notEqual(c1.challenge, c2.challenge, 'challenges are never reused');
  assert.notEqual(c1.challenge_id, c2.challenge_id);
  assert.ok(Buffer.from(c1.challenge, 'base64').length >= 32, '>= 32 bytes of entropy');
  assert.ok(c1.expires_at_ms > Date.now(), 'not already expired');
  first.disconnect();
  second.disconnect();
});

test('4. invalid signature -> AUTH_FAILED', async () => {
  const identity = await world.seedIdentity();
  const client = world.client(identity);
  client.connect();
  const code = await attempt(() =>
    client.authenticate({ signatureBase64: Buffer.alloc(64, 7).toString('base64') }),
  );
  assert.equal(code, 'AUTH_FAILED');
  await client.next('disconnect');
  client.disconnect();
});

test('5. signature from a NON-registered key -> AUTH_FAILED', async () => {
  const identity = await world.seedIdentity();
  const { privateKey } = generateKeyPairSync('ed25519');
  const client = world.client(identity);
  client.connect();
  const code = await attempt(() => client.authenticate({ signingKey: privateKey }));
  assert.equal(code, 'AUTH_FAILED');
  client.disconnect();
});

test('6. expired challenge -> AUTH_FAILED', async () => {
  const shortLived = new RealtimeServer({ config: { challengeTtlMs: 120 } });
  const port = await shortLived.start({ host: '127.0.0.1' });
  try {
    const identity = createIdentity({ accountId: 'acc-exp', deviceId: 'dev-exp' });
    await shortLived.adminRegisterDevice({
      accountId: identity.accountId,
      deviceId: identity.deviceId,
      novaId: identity.novaId,
      publicKeyBase64: identity.publicKeyBase64,
    });
    const client = new NovaClient({ url: `http://127.0.0.1:${port}`, identity });
    client.connect();
    await client.next('connect');
    const challenge = await client.nextChallenge();
    await sleep(250); // let the challenge expire
    const code = await attempt(() => client.authenticate({ challenge }));
    assert.equal(code, 'AUTH_FAILED');
    client.disconnect();
  } finally {
    await shortLived.stop();
  }
});

test('7. reused challenge (replay) -> AUTH_FAILED', async () => {
  const identity = await world.seedIdentity();
  const first = world.client(identity);
  first.connect();
  await first.next('connect');
  const challenge = await first.nextChallenge();
  const payload = first.buildAuthResponse(challenge);
  await first.sendAuthResponse(payload); // burns the challenge legitimately

  // A second socket replays the exact same signed payload.
  const replay = world.client(identity);
  replay.connect();
  await replay.next('connect');
  await replay.nextChallenge();
  const code = await attempt(() => replay.sendAuthResponse(payload));
  assert.equal(code, 'AUTH_FAILED', 'a replayed challenge never authenticates');

  first.disconnect();
  replay.disconnect();
});

test('8. the same challenge cannot authenticate twice on its own socket', async () => {
  const identity = await world.seedIdentity();
  const client = world.client(identity);
  client.connect();
  await client.next('connect');
  const challenge = await client.nextChallenge();
  const payload = client.buildAuthResponse(challenge);

  // First attempt is deliberately broken -> the challenge is BURNED anyway.
  const firstCode = await attempt(() =>
    client.sendAuthResponse({ ...payload, signature: Buffer.alloc(64).toString('base64') }),
  );
  assert.equal(firstCode, 'AUTH_FAILED');

  const retry = world.client(identity);
  retry.connect();
  await retry.next('connect');
  await retry.nextChallenge();
  const code = await attempt(() => retry.sendAuthResponse(payload));
  assert.equal(code, 'AUTH_FAILED', 'a burned challenge is gone for good');

  client.disconnect();
  retry.disconnect();
});

test('9. modified challenge bytes -> AUTH_FAILED', async () => {
  const identity = await world.seedIdentity();
  const client = world.client(identity);
  client.connect();
  await client.next('connect');
  const challenge = await client.nextChallenge();
  const tampered = Buffer.from(challenge.challenge, 'base64');
  tampered[0] ^= 0xff; // flip a bit of the challenge the client signs
  const payload = client.buildAuthResponse({
    ...challenge,
    challenge: tampered.toString('base64'),
  });
  const code = await attempt(() => client.sendAuthResponse(payload));
  assert.equal(code, 'AUTH_FAILED');
  client.disconnect();
});

test('10. wrong Device ID -> AUTH_FAILED', async () => {
  const identity = await world.seedIdentity();
  const other = await world.seedIdentity();
  const client = world.client(identity);
  client.connect();
  // Claims another device's id, signed with its own key.
  const code = await attempt(() => client.authenticate({ deviceId: other.deviceId }));
  assert.equal(code, 'AUTH_FAILED');
  client.disconnect();
});

test('11. wrong Account ID -> AUTH_FAILED', async () => {
  const identity = await world.seedIdentity();
  const client = world.client(identity);
  client.connect();
  const code = await attempt(() => client.authenticate({ accountId: 'acc-not-mine' }));
  assert.equal(code, 'AUTH_FAILED');
  client.disconnect();
});

test('12. wrong Nova ID -> AUTH_FAILED', async () => {
  const identity = await world.seedIdentity();
  const client = world.client(identity);
  client.connect();
  const code = await attempt(() => client.authenticate({ novaId: 'NOVA-IMPOSTOR' }));
  assert.equal(code, 'AUTH_FAILED');
  client.disconnect();
});

test('13. unknown device -> AUTH_FAILED (never "unknown account")', async () => {
  const ghost = createIdentity({ accountId: 'acc-ghost', deviceId: 'dev-ghost' });
  const client = world.client(ghost);
  client.connect();
  const code = await attempt(() => client.authenticate());
  assert.equal(code, 'AUTH_FAILED');
  client.disconnect();
});

test('14. revoked device: session killed, socket closed, re-auth refused', async () => {
  const identity = await world.seedIdentity({ accountId: 'acc-revoked' });
  const client = world.client(identity);
  client.connect();
  const success = await client.authenticate();

  const result = await world.server.adminRevokeDevice(identity.deviceId);
  assert.equal(result.revoked, true);
  assert.equal(result.sessionsKilled, 1);

  const revoked = (await client.next('device.revoked')) as Record<string, unknown>;
  assert.equal(revoked['device_id'], identity.deviceId);
  await client.next('disconnect');
  assert.equal(world.server.sessions.bySessionId(success.session_id), null);
  assert.equal(client.state, 'blocked', 'the client refuses to reconnect');

  // A brand-new socket cannot re-authenticate that device either.
  const retry = new NovaClient({ url: world.url, identity, name: 'revoked-retry' });
  retry.connect();
  const code = await attempt(() => retry.authenticate());
  assert.equal(code, 'AUTH_FAILED');
  retry.disconnect();
  client.disconnect();
});

test('15. expired session -> SESSION_EXPIRED on the next event', async () => {
  const shortSession = new RealtimeServer({ config: { sessionTtlMs: 200 } });
  const port = await shortSession.start({ host: '127.0.0.1' });
  try {
    const identity = createIdentity({ accountId: 'acc-ttl', deviceId: 'dev-ttl' });
    await shortSession.adminRegisterDevice({
      accountId: identity.accountId,
      deviceId: identity.deviceId,
      novaId: identity.novaId,
      publicKeyBase64: identity.publicKeyBase64,
    });
    await shortSession.adminAddConversationMember('conv-ttl', identity.accountId);
    const client = new NovaClient({ url: `http://127.0.0.1:${port}`, identity });
    client.connect();
    await client.authenticate();
    await sleep(320);
    client.emitRaw('sync.request', { conversation_id: 'conv-ttl', last_seq: 0 });
    const error = (await client.next('system.error')) as Record<string, unknown>;
    assert.equal(error['code'], 'SESSION_EXPIRED');
    await client.next('disconnect');
    client.disconnect();
  } finally {
    await shortSession.stop();
  }
});

test('16. every cryptographic rejection answers the SAME generic code', async () => {
  const identity = await world.seedIdentity({ accountId: 'acc-oracle' });
  const other = await world.seedIdentity();
  const { privateKey } = generateKeyPairSync('ed25519');
  const ghost = createIdentity({ accountId: 'acc-x', deviceId: 'dev-x' });

  const codes: string[] = [];
  const cases: Array<() => Promise<unknown>> = [
    () => {
      const c = world.client(ghost);
      c.connect();
      return c.authenticate(); // unknown device
    },
    () => {
      const c = world.client(identity);
      c.connect();
      return c.authenticate({ signingKey: privateKey }); // wrong key
    },
    () => {
      const c = world.client(identity);
      c.connect();
      return c.authenticate({ accountId: 'acc-nope' }); // wrong account
    },
    () => {
      const c = world.client(identity);
      c.connect();
      return c.authenticate({ deviceId: other.deviceId }); // wrong device
    },
    () => {
      const c = world.client(identity);
      c.connect();
      return c.authenticate({ novaId: 'NOVA-NOPE' }); // wrong nova id
    },
  ];
  for (const run of cases) codes.push(await attempt(run));

  assert.deepEqual(
    codes,
    codes.map(() => 'AUTH_FAILED'),
    'the wire code must not reveal WHICH check failed',
  );
});

test('17. no event is accepted before auth.success', async () => {
  const identity = await world.seedIdentity();
  const client = world.client(identity);
  client.connect();
  await client.next('connect');
  await client.nextChallenge(); // handshake deliberately left incomplete

  client.emitRaw('message.send', {
    message_id: 'msg-premature',
    conversation_id: 'conv-any',
    ciphertext: Buffer.from('x').toString('base64'),
    header_type: 'dr.v1',
  });
  const error = (await client.next('system.error')) as Record<string, unknown>;
  assert.equal(error['code'], 'FORBIDDEN');
  assert.equal(error['event'], 'message.send');
  await client.next('disconnect');
  client.disconnect();
});
