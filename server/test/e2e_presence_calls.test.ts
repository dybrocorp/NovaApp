/**
 * E2E — Presence & call signaling.
 *
 * Presence fans out ONLY to the subject's privacy audience (never
 * global). Call events are WebRTC SIGNALING RELAY only (no media flows
 * through Socket.IO), gated by a contact relationship, with server-stamped
 * identity fields so a client can never spoof the sender.
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { RealtimeServer } from '../src/realtime_server.js';
import { TestWorld, seedConversation, seedUser } from './helpers.js';

const world = new TestWorld(() => new RealtimeServer());

let alice: Awaited<ReturnType<typeof seedUser>>;
let bob: Awaited<ReturnType<typeof seedUser>>;
let carol: Awaited<ReturnType<typeof seedUser>>;

before(async () => {
  await world.start();
  alice = await seedUser(world.server, { accountId: 'acc-pres-a' });
  bob = await seedUser(world.server, { accountId: 'acc-pres-b' });
  carol = await seedUser(world.server, { accountId: 'acc-pres-c' });
  // Bob is in Alice's presence audience; Carol is not.
  await world.server.adminAllowPresence(alice.accountId, bob.accountId);
  // Alice <-> Bob are contacts; Carol is a stranger to both.
  await world.server.adminAddRelationship(alice.accountId, bob.accountId);
  await seedConversation(world.server, 'conv-pres', [alice.accountId, bob.accountId]);
});

after(async () => {
  await world.stop();
});

test('1. presence.update fans out to the privacy audience', async () => {
  const a = world.client();
  const b = world.client();
  await a.authenticate(alice);
  await b.authenticate(bob);
  a.emit('presence.update', { status: 'online' });
  const changed = (await b.next('presence.changed')) as Record<string, unknown>;
  assert.equal(changed['account_id'], alice.accountId);
  assert.equal(changed['status'], 'online');
  assert.ok(typeof changed['last_seen_ms'] === 'number');
  a.disconnect();
  b.disconnect();
});

test('2. accounts outside the audience receive nothing', async () => {
  const a = world.client();
  const b = world.client();
  const c = world.client();
  await a.authenticate(alice);
  await b.authenticate(bob);
  await c.authenticate(carol);
  a.emit('presence.update', { status: 'online' });
  await b.next('presence.changed'); // audience member gets it
  await c.expectNone('presence.changed', 250); // Carol does not
  a.disconnect();
  b.disconnect();
  c.disconnect();
});

test('3. presence.update before auth -> FORBIDDEN + disconnect', async () => {
  const client = world.client();
  await client.ready();
  await client.challenge();
  client.emit('presence.update', { status: 'online' });
  const error = await client.next('system.error');
  assert.equal((error as { code: string }).code, 'FORBIDDEN');
  await client.onDisconnect();
  client.disconnect();
});

test('4. call.offer is relayed to the related peer', async () => {
  const a = world.client();
  const b = world.client();
  await a.authenticate(alice);
  await b.authenticate(bob);
  a.emit('call.offer', { peer_account_id: bob.accountId, sdp: 'v=0 offer' });
  const offer = (await b.next('call.offer')) as Record<string, unknown>;
  assert.equal(offer['from_account_id'], alice.accountId);
  assert.equal(offer['from_device_id'], alice.deviceId);
  assert.equal(offer['sdp'], 'v=0 offer', 'signaling payload relayed opaquely');
  a.disconnect();
  b.disconnect();
});

test('5. call signaling to a non-contact -> FORBIDDEN', async () => {
  const a = world.client();
  await a.authenticate(alice);
  a.emit('call.offer', { peer_account_id: carol.accountId, sdp: 'v=0' });
  const error = await a.next('system.error');
  assert.equal((error as { code: string }).code, 'FORBIDDEN');
  assert.equal((error as { event: string }).event, 'call.offer');
  a.disconnect();
});

test('6. client-stamped identity fields are stripped (anti-spoof)', async () => {
  const a = world.client();
  const b = world.client();
  await a.authenticate(alice);
  await b.authenticate(bob);
  a.emit('call.ice', {
    peer_account_id: bob.accountId,
    from_account_id: 'acc-attacker', // spoof attempt
    candidate: 'candidate:1 1 udp',
  });
  const ice = (await b.next('call.ice')) as Record<string, unknown>;
  assert.equal(ice['from_account_id'], alice.accountId, 'identity is server-stamped');
  assert.equal(ice['candidate'], 'candidate:1 1 udp');
  a.disconnect();
  b.disconnect();
});
