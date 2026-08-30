/**
 * FASE 1 (port) — E2E: delete-for-everyone tombstones + expiring-message
 * server purge. These contracts were audited and implemented on
 * `arena/01a04505-novaapp` (head e15325c) and ported onto this
 * architecture: the server redacts BY LOGICAL message id across per-device
 * copies, rewrites the event log so replay yields a tombstone (never
 * ciphertext), authorizes senders only, and sweeps elapsed `expires_at_ms`
 * on its own clock (never trusting a client to do it).
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { World } from './world.js';
import type { NovaIdentity } from '../src/client/nova_client.js';

const CONV = 'conv-del-expiry';
const CONV_LATE = 'conv-late-joiner';

let now = Date.now();
// Fast sweep so the expiry test does not wait the production 5 s default.
const world = new World({
  config: { messagePurgeIntervalMs: 50 },
  clock: () => now,
});

let alice: NovaIdentity;
let bob: NovaIdentity;
let mallory: NovaIdentity;

before(async () => {
  now = Date.now();
  await world.start();
  alice = await world.seedIdentity({ accountId: 'acc-DELE-A', deviceId: 'dev-DELE-A' });
  bob = await world.seedIdentity({ accountId: 'acc-DELE-B', deviceId: 'dev-DELE-B' });
  mallory = await world.seedIdentity({ accountId: 'acc-DELE-M', deviceId: 'dev-DELE-M' });
  await world.conversation(CONV, [alice.accountId, bob.accountId]);
  await world.conversation(CONV_LATE, [alice.accountId, bob.accountId, mallory.accountId]);
});

after(async () => {
  await world.stop();
});

test('1. sender delete: room gets message.deleted, sender acked via broadcast', async () => {
  const a = await world.connected(alice, 'del-A');
  const b = await world.connected(bob, 'del-B');

  const messageId = a.sendEnvelope({
    conversationId: CONV,
    ciphertextBase64: 'YWxpY2UtY2lwaGVydGV4dA==',
    headerType: 'dr.v1',
  });
  await a.next('message.ack');
  await b.next('message.new');

  b.emitRaw('message.delete', { conversation_id: CONV, message_id: messageId });
  const err = (await b.next('system.error')) as Record<string, unknown>;
  assert.equal(err['code'], 'FORBIDDEN', 'a non-sender cannot delete');

  a.emitRaw('message.delete', { conversation_id: CONV, message_id: messageId });
  const tombA = (await a.next('message.deleted')) as Record<string, unknown>;
  const tombB = (await b.next('message.deleted')) as Record<string, unknown>;
  assert.equal(tombA['message_id'], messageId);
  assert.equal(tombB['by_account_id'], alice.accountId);
  assert.equal(tombB['conversation_id'], CONV);
});

test('2. tombstoned ciphertext cannot be resurrected through sync', async () => {
  // Fresh client syncing from zero AFTER the delete above: the log entry
  // for the deleted message must replay as a tombstone view — no ciphertext.
  const late = await world.connected(bob, 'sync-after-delete');
  const response = await late.sync(CONV);
  const events = (response['events'] ?? []) as Array<Record<string, unknown>>;
  const newEvents = events.filter((e) => e['type'] === 'message.new');
  assert.ok(newEvents.length >= 1, 'conversation has history');
  for (const ev of newEvents) {
    if (ev['deleted'] === true) {
      assert.equal(ev['ciphertext'], null, 'tombstones carry NO ciphertext');
    }
    // And no live event may contain the deleted id with content.
    if (typeof ev['message_id'] === 'string' && ev['deleted'] !== true) {
      assert.notEqual(
        JSON.stringify(ev['payload'] ?? ev).includes('YWxpY2UtY2lwaGVydGV4dA=='),
        true,
        'deleted ciphertext must not appear anywhere in replay',
      );
    }
  }
  const tombstones = events.filter((e) => e['type'] === 'message.deleted');
  assert.ok(tombstones.length >= 1, 'the tombstone event is replayable');
});

test('3. elapsed expires_at_ms is purged server-side + message.expired fans out', async () => {
  const a = await world.connected(alice, 'purge-A');
  const b = await world.connected(bob, 'purge-B');

  const messageId = a.sendEnvelope({
    conversationId: CONV,
    ciphertextBase64: 'ZXBoZW1lcmFsbA==',
    headerType: 'dr.v1',
    extra: { expires_at_ms: now + 500 },
  });
  await a.next('message.ack');
  await b.next('message.new');

  // Advance the shared fake clock past expiry; the 50 ms sweep fires.
  now += 600;
  const expired = (await b.next('message.expired', 3000)) as Record<string, unknown>;
  assert.equal(expired['message_id'], messageId);
  assert.equal(expired['conversation_id'], CONV);

  // The purged ciphertext is gone from the log too (replay = tombstone).
  const late = await world.connected(bob, 'purge-late');
  const response = await late.sync(CONV);
  for (const ev of (response['events'] ?? []) as Array<Record<string, unknown>>) {
    if (ev['message_id'] === messageId && ev['type'] === 'message.new') {
      assert.equal(ev['deleted'], true);
      assert.equal(ev['ciphertext'], null);
      assert.equal(ev['deleted_reason'], 'expired');
    }
  }
});

test('4. expired purge is idempotent across sweeps (no event storms)', async () => {
  const before = world.logs.lines.filter((l) => l.includes('message.expired_purge')).length;
  // Let several sweep ticks pass with nothing expiring.
  now += 1000;
  await new Promise((r) => setTimeout(r, 300));
  const after = world.logs.lines.filter((l) => l.includes('message.expired_purge')).length;
  assert.ok(after - before <= 1, 'idle sweeps purge nothing (bounded log noise)');
});

test('5. unknown/foreign message ids get one generic rejection (no existence leak)', async () => {
  const m = await world.connected(mallory, 'probe-M');
  // Not a member of CONV → cannot even probe; member-but-not-sender path
  // is covered by test 1. Both must yield the SAME error code.
  m.emitRaw('message.delete', { conversation_id: CONV, message_id: 'never-existed' });
  const err = (await m.next('system.error', 3000)) as Record<string, unknown>;
  assert.equal(err['code'], 'FORBIDDEN');
  assert.equal(err['event'], 'message.delete');
});
