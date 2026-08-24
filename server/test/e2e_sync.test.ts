/**
 * E2E — Sync (sync.request / sync.response).
 *
 * After a reconnection (or a wifi<->mobile network switch) the client
 * catches up from its last cursor: the server replays the conversation
 * event log ordered by server_seq, never trusting client timestamps.
 * Membership is enforced: sync of a foreign conversation is FORBIDDEN.
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { RealtimeServer } from '../src/realtime_server.js';
import { TestWorld, seedConversation, seedUser } from './helpers.js';

const world = new TestWorld(() => new RealtimeServer());

const CONV = 'conv-sync';
let alice: Awaited<ReturnType<typeof seedUser>>;
let bob: Awaited<ReturnType<typeof seedUser>>;

before(async () => {
  await world.start();
  alice = await seedUser(world.server, { accountId: 'acc-sync-a' });
  bob = await seedUser(world.server, { accountId: 'acc-sync-b' });
  await seedConversation(world.server, CONV, [alice.accountId, bob.accountId]);

  // Three messages exist in the conversation before any sync.
  const a = world.client();
  await a.authenticate(alice);
  for (let i = 0; i < 3; i++) {
    await a.sendMessage({ conversationId: CONV, identity: alice });
  }
  a.disconnect();
});

after(async () => {
  await world.stop();
});

test('1. sync from cursor 0 replays all events in server_seq order', async () => {
  const b = world.client();
  await b.authenticate(bob);
  b.emit('sync.request', { conversation_id: CONV, last_seq: 0 });
  const response = (await b.next('sync.response')) as Record<string, unknown>;
  const events = response['events'] as Array<Record<string, unknown>>;
  assert.equal(events.length, 3);
  const seqs = events.map((event) => event['server_seq'] as number);
  assert.deepEqual(seqs, [...seqs].sort((x, y) => x - y), 'ordered by server_seq');
  assert.equal(events.every((event) => event['type'] === 'message.new'), true);
  assert.equal(response['cursor'], seqs[seqs.length - 1], 'cursor is the latest seq');
  b.disconnect();
});

test('2. sync from a middle cursor returns only newer events', async () => {
  const b = world.client();
  await b.authenticate(bob);
  b.emit('sync.request', { conversation_id: CONV, last_seq: 1 });
  const response = (await b.next('sync.response')) as Record<string, unknown>;
  const events = response['events'] as Array<Record<string, unknown>>;
  assert.equal(events.length, 2);
  assert.ok(events.every((event) => (event['server_seq'] as number) > 1));
  b.disconnect();
});

test('3. up-to-date cursor -> empty batch, cursor unchanged', async () => {
  const b = world.client();
  await b.authenticate(bob);
  b.emit('sync.request', { conversation_id: CONV, last_seq: 3 });
  const response = (await b.next('sync.response')) as Record<string, unknown>;
  assert.deepEqual(response['events'], []);
  assert.equal(response['cursor'], 3);
  b.disconnect();
});

test('4. sync of a non-member conversation -> FORBIDDEN', async () => {
  const stranger = await seedUser(world.server, { accountId: 'acc-sync-stranger' });
  const s = world.client();
  await s.authenticate(stranger);
  s.emit('sync.request', { conversation_id: CONV, last_seq: 0 });
  const error = await s.next('system.error');
  assert.equal((error as { code: string }).code, 'FORBIDDEN');
  assert.equal((error as { event: string }).event, 'sync.request');
  s.disconnect();
});
