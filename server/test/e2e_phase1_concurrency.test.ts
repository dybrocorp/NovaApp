/**
 * FASE 1.1 §15/§16 — CONCURRENCIA y reconexión a mitad de ráfaga.
 *
 * Garantías que fija esta suite (contrato "sin duplicados, sin pérdida"):
 *   * N mensajes enviados en ráfaga por el MISMO socket reciben acks en
 *     orden y `server_seq` estrictamente contiguo y creciente;
 *   * cada copia llega al destinatario exactamente una vez (dedup por
 *     message_id por dispositivo);
 *   * un corte de conexión a mitad de ráfaga NO pierde ni duplica: los
 *     sin-ack viven en el outbox del cliente y se reenvían con el MISMO
 *     id lógico (idempotencia en el servidor);
 *   * un replay completo de la ráfaga (acks perdidos simulados) no añade
 *     filas ni eventos nuevos.
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { World } from './world.js';
import type { NovaIdentity } from '../src/client/nova_client.js';

const CONV = 'conv-burst-1';
const CONV_CUT = 'conv-burst-2';

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const world = new World();

let alice: NovaIdentity;
let bob: NovaIdentity;

before(async () => {
  await world.start();
  alice = await world.seedIdentity({ accountId: 'acc-BURST-A', deviceId: 'dev-BURST-A' });
  bob = await world.seedIdentity({ accountId: 'acc-BURST-B', deviceId: 'dev-BURST-B' });
  await world.conversation(CONV, [alice.accountId, bob.accountId]);
  await world.conversation(CONV_CUT, [alice.accountId, bob.accountId]);
});

after(async () => {
  await world.stop();
});

const ct = (text: string) => Buffer.from(text).toString('base64');

test('1. burst of 5 back-to-back sends: contiguous seqs, one copy each, replay-safe', async () => {
  const a = await world.connected(alice, 'burst-A');
  const b = await world.connected(bob, 'burst-B');

  const ids: string[] = [];
  for (let i = 0; i < 5; i += 1) {
    ids.push(
      a.sendEnvelope({
        conversationId: CONV,
        ciphertextBase64: ct(`opaque-ciphertext-${i}`),
        messageId: `burst-m${i}`,
      }),
    );
  }

  // Acks: same FIFO order as the emits (single socket ⇒ single TCP order).
  const ackSeqs: number[] = [];
  for (let i = 0; i < 5; i += 1) {
    const ack = (await a.next('message.ack')) as Record<string, unknown>;
    assert.equal(ack['message_id'], ids[i], `ack ${i} must answer send ${i}`);
    ackSeqs.push(Number(ack['server_seq']));
  }
  assert.deepEqual(
    ackSeqs,
    [1, 2, 3, 4, 5],
    'server_seq must be contiguous and in send order for the burst',
  );

  // Bob: five inbound copies, exactly-once, same seq order.
  for (let i = 0; i < 5; i += 1) {
    const ev = (await b.next('message.new')) as Record<string, unknown>;
    assert.equal(ev['message_id'], ids[i]);
    assert.equal(Number(ev['server_seq']), i + 1);
  }
  assert.equal(b.inbox.size, 5, 'no duplicates reached the inbox');

  // Replay the whole burst (simulates lost acks on the client) — the
  // server-side dedup must make it a no-op, loudly (acks repeat, no rows).
  for (let i = 0; i < 5; i += 1) {
    a.sendEnvelope({
      conversationId: CONV,
      ciphertextBase64: ct(`opaque-ciphertext-${i}`),
      messageId: `burst-m${i}`,
      force: true,
    } as Parameters<typeof a.sendEnvelope>[0]);
    const ack = (await a.next('message.ack')) as Record<string, unknown>;
    assert.equal(ack['message_id'], ids[i]);
    assert.equal(Number(ack['server_seq']), i + 1, 'replay acks the ORIGINAL seq');
  }
  await b.expectNone('message.new', 200);
  assert.equal(b.inbox.size, 5, 'replay must not create a second copy');
});

test('2. sync after the burst: 5 events, cursor never skips, re-apply dedups', async () => {
  const b = await world.connected(bob, 'burst-B-sync');
  const response = await b.sync(CONV);
  const conversations = response['conversations'] as Array<Record<string, unknown>>;
  const entry = conversations.find((c) => c['conversation_id'] === CONV);
  assert.ok(entry, 'the burst conversation is present in sync');
  const events = (entry as Record<string, unknown>)['events'] as Array<Record<string, unknown>>;
  const newOnes = events.filter((e) => e['type'] === 'message.new');
  assert.equal(newOnes.length, 5, 'sync replays the burst once, no more');
  const seqs = newOnes.map((e) => Number(e['server_seq']));
  assert.deepEqual(seqs, [1, 2, 3, 4, 5], 'sync order is server_seq order');

  // sync() already applied the batch client-side (dedup inbox + cursors).
  assert.equal(b.inbox.size, 5, 'sync populated the inbox exactly once');
  const second = b.applySync(response);
  assert.equal(second.applied, 0, 're-applying the same response is pure dedup');
  assert.equal(second.duplicates, 5);
});

test('3. connection cut mid-burst: queued sends flush on reconnect, exactly-once', async () => {
  const a = await world.connected(alice, 'cut-A');
  const b = await world.connected(bob, 'cut-B');

  // First two go through.
  for (const i of [0, 1]) {
    await a.sendAndAwaitAck({
      conversationId: CONV_CUT,
      ciphertextBase64: ct(`cut-ok-${i}`),
      messageId: `cut-m${i}`,
    });
  }

  // The rest of the burst is emitted and the socket is cut in the same
  // synchronous block: no ack can be observed before the drop, so the
  // client-side outbox provably holds them (same race pattern as the
  // reconnect suite, but deterministic: JS runs these lines uninterrupted).
  const late: string[] = [];
  for (const i of [2, 3, 4]) {
    late.push(
      a.sendEnvelope({
        conversationId: CONV_CUT,
        ciphertextBase64: ct(`cut-late-${i}`),
        messageId: `cut-m${i}`,
      }),
    );
  }
  a.dropConnection();
  const pending = a.pending();
  for (const id of late) {
    assert.ok(pending.includes(id), `${id} must be pending while offline`);
  }

  // Reconnect, authenticate, flush: retries carry the SAME logical ids.
  a.connect();
  await a.authenticate();
  const resent = a.flushOutbox();
  assert.deepEqual([...resent].sort(), [...late].sort(), 'flush retries exactly the un-acked ids');
  for (const id of late) {
    await a.waitForAck(id, 4000);
  }

  await sleep(250);
  assert.equal(b.inbox.size, 5, 'all five arrived, none lost');
  for (const id of late.concat(['cut-m0', 'cut-m1'])) {
    assert.ok(b.inbox.has(id), `${id} must be in the inbox exactly once`);
  }

  a.disconnect();
  b.disconnect();
});
