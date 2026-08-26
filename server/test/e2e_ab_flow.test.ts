/**
 * FASE 0.5 — E2E: NOVA CLIENT A  <->  REALTIME SERVER  <->  NOVA CLIENT B
 *
 * The core end-to-end proof required by FASE 0.5 §2-§7:
 *
 *   CLIENT A -> E2EE -> ciphertext -> Socket.IO/WSS -> SERVER -> store
 *            -> Socket.IO/WSS -> CLIENT B -> E2EE decryption
 *
 * A and B are TWO DIFFERENT ACCOUNTS with SEPARATE cryptographic
 * identities (own Ed25519 handshake key, own X3DH bundle, own ratchet).
 * No key material is shared between them.
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { World } from './world.js';
import type { NovaClient } from '../src/client/nova_client.js';
import type { NovaIdentity } from '../src/client/nova_client.js';
import {
  RatchetSession,
  X3DHDevice,
  packEnvelope,
  unpackEnvelope,
  x3dhReceiver,
  x3dhSender,
} from '../src/client/e2ee.js';
import { FORBIDDEN_PLAINTEXT_KEYS } from '../src/realtime_server.js';
import { MemoryRealtimeStore } from '../src/store/realtime_store.js';

const CONV = 'conv-ab';
const store = new MemoryRealtimeStore();
const world = new World({ store });

let identityA: NovaIdentity;
let identityB: NovaIdentity;

// Independent crypto identities — nothing is shared between A and B.
const deviceA = new X3DHDevice();
const deviceB = new X3DHDevice();
let ratchetA: RatchetSession;
let ratchetB: RatchetSession;

before(async () => {
  await world.start();
  identityA = await world.seedIdentity({ accountId: 'acc-A', deviceId: 'dev-A' });
  identityB = await world.seedIdentity({ accountId: 'acc-B', deviceId: 'dev-B' });
  await world.conversation(CONV, [identityA.accountId, identityB.accountId]);

  // X3DH: A fetches B's bundle and derives the shared secret.
  const sender = x3dhSender(deviceA, deviceB.bundle());
  const bobSecret = x3dhReceiver(deviceB, {
    senderIdentityRaw: deviceA.identity.publicRaw,
    senderEphemeralRaw: sender.ephemeralPublicRaw,
    usedOneTimePreKey: sender.usedOneTimePreKey,
  });
  assert.ok(
    sender.sharedSecret.equals(bobSecret),
    'X3DH must converge on the same secret for A and B',
  );
  ratchetA = RatchetSession.initSender(sender.sharedSecret, deviceB.signedPreKey.publicRaw);
  ratchetB = RatchetSession.initReceiver(bobSecret, deviceB.signedPreKey);
});

after(async () => {
  await world.stop();
});

test('1. A and B authenticate independently (two accounts, two identities)', async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');

  assert.equal(a.session?.account_id, identityA.accountId);
  assert.equal(b.session?.account_id, identityB.accountId);
  assert.notEqual(a.session?.session_id, b.session?.session_id);
  assert.notEqual(
    identityA.publicKeyBase64,
    identityB.publicKeyBase64,
    'A and B must NOT share cryptographic identity',
  );
  assert.equal(a.authenticated, true);
  assert.equal(b.authenticated, true);

  a.disconnect();
  b.disconnect();
});

test('2. A -> ciphertext -> server -> B, and B decrypts the plaintext', async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');

  const plaintext = 'Hola B, este es un mensaje E2EE de A.';
  const body = ratchetA.encrypt(plaintext);
  const ciphertextBase64 = packEnvelope(body);

  const { messageId, ack } = await a.sendAndAwaitAck({
    conversationId: CONV,
    ciphertextBase64,
  });
  assert.equal(ack['message_id'], messageId);
  assert.equal(typeof ack['server_seq'], 'number');

  const inbound = (await b.next('message.new')) as Record<string, unknown>;
  assert.equal(inbound['message_id'], messageId);
  assert.equal(inbound['sender_account_id'], identityA.accountId);
  assert.equal(inbound['ciphertext'], ciphertextBase64);

  const decrypted = ratchetB.decrypt(unpackEnvelope(inbound['ciphertext'] as string));
  assert.equal(decrypted, plaintext, 'B must recover exactly what A sent');

  a.disconnect();
  b.disconnect();
});

test('3. the server never sees plaintext (stored + relayed blobs are opaque)', async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');

  const secret = 'CLAVE-SECRETA-QUE-EL-SERVIDOR-NUNCA-DEBE-VER';
  const ciphertextBase64 = packEnvelope(ratchetA.encrypt(secret));
  const { messageId } = await a.sendAndAwaitAck({ conversationId: CONV, ciphertextBase64 });
  await b.next('message.new');

  const stored = store.allMessages().find((m) => m.messageId === messageId);
  assert.ok(stored, 'message persisted');
  const asJson = JSON.stringify(stored);
  assert.equal(asJson.includes(secret), false, 'plaintext must not be stored');
  assert.equal(
    Buffer.from(stored!.ciphertextBase64, 'base64').toString('utf8').includes(secret),
    false,
    'ciphertext must not decode to plaintext',
  );
  // The stored record carries no plaintext-ish field at all.
  for (const key of FORBIDDEN_PLAINTEXT_KEYS) {
    assert.equal(
      Object.prototype.hasOwnProperty.call(stored as object, key),
      false,
      `stored record must not carry '${key}'`,
    );
  }

  a.disconnect();
  b.disconnect();
});

test('4. an envelope carrying a plaintext field is rejected (PAYLOAD_INVALID)', async () => {
  const a = await world.connected(identityA, 'A');
  for (const key of ['plaintext', 'text', 'content', 'body', 'message']) {
    a.emitRaw('message.send', {
      message_id: `msg-plain-${key}`,
      conversation_id: CONV,
      ciphertext: Buffer.from('opaque').toString('base64'),
      header_type: 'dr.v1',
      [key]: 'contenido en claro',
    });
    const error = (await a.next('system.error')) as Record<string, unknown>;
    assert.equal(error['code'], 'PAYLOAD_INVALID', `key '${key}' must be refused`);
  }
  a.disconnect();
});

test('5. message_id is idempotent: the same event twice creates ONE message', async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');

  const ciphertextBase64 = packEnvelope(ratchetA.encrypt('mensaje idempotente'));
  const messageId = `msg-idem-${Date.now()}`;

  a.sendEnvelope({ conversationId: CONV, ciphertextBase64, messageId });
  const first = await a.waitForAck(messageId);
  assert.equal(first['duplicate'], undefined, 'first send is not a duplicate');

  // Exact same event re-emitted: the client never saw the first ack
  // (e.g. it was lost on a dying socket) and retransmits.
  a.sendEnvelope({ conversationId: CONV, ciphertextBase64, messageId, force: true });
  const second = await a.waitForAck(messageId);
  assert.equal(second['duplicate'], true, 'retry answers the idempotent result');
  assert.equal(
    second['server_seq'],
    first['server_seq'],
    'retry returns the ORIGINAL server_seq',
  );

  // B receives it exactly once.
  const inbound = (await b.next('message.new')) as Record<string, unknown>;
  assert.equal(inbound['message_id'], messageId);
  await b.expectNone('message.new', 300);

  const copies = store.allMessages().filter((m) => m.messageId === messageId);
  assert.equal(copies.length, 1, 'exactly one persisted message');

  a.disconnect();
  b.disconnect();
});

test('6. ACK / DELIVERED / READ are three distinct, non-conflated states', async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');

  const ciphertextBase64 = packEnvelope(ratchetA.encrypt('estado de entrega'));
  const { messageId, ack } = await a.sendAndAwaitAck({ conversationId: CONV, ciphertextBase64 });

  // 1) SENT: the ack means "server received + persisted", nothing more.
  assert.equal(ack['message_id'], messageId);
  const serverSeq = ack['server_seq'] as number;
  await a.expectNone('message.delivered', 200);
  await a.expectNone('message.read', 200);

  const inbound = (await b.next('message.new')) as Record<string, unknown>;
  assert.equal(inbound['message_id'], messageId);

  // 2) DELIVERED: emitted by the RECIPIENT device.
  b.markDelivered(CONV, messageId);
  const delivered = (await a.next('message.delivered')) as Record<string, unknown>;
  assert.equal(delivered['message_id'], messageId);
  assert.equal(delivered['by_account_id'], identityB.accountId);
  assert.equal(delivered['server_seq'], serverSeq);
  await a.expectNone('message.read', 200);

  // 3) READ: separate event, high-water mark.
  b.markRead(CONV, serverSeq);
  const read = (await a.next('message.read')) as Record<string, unknown>;
  assert.equal(read['by_account_id'], identityB.accountId);
  assert.equal(read['last_read_seq'], serverSeq);

  a.disconnect();
  b.disconnect();
});

test('7. READ high-water mark cannot be pushed beyond the server sequence', async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');
  const latest = await store.latestSeq(CONV);

  b.markRead(CONV, latest + 9999); // client claims to have read the future
  const read = (await a.next('message.read')) as Record<string, unknown>;
  assert.equal(read['last_read_seq'], latest, 'clamped to the real sequence');

  a.disconnect();
  b.disconnect();
});

test('8. server_seq orders the conversation, not client timestamps', async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');

  const seqs: number[] = [];
  for (let i = 0; i < 5; i += 1) {
    const ciphertextBase64 = packEnvelope(ratchetA.encrypt(`ordenado ${i}`));
    // Client timestamps go BACKWARDS on purpose: they must be ignored.
    const messageId = `msg-order-${Date.now()}-${i}`;
    a.sendEnvelope({
      conversationId: CONV,
      ciphertextBase64,
      messageId,
      extra: { client_ts_ms: 1_000_000 - i * 1000 },
    });
    const ack = await a.waitForAck(messageId);
    seqs.push(ack['server_seq'] as number);
  }
  assert.deepEqual(seqs, [...seqs].sort((x, y) => x - y), 'server_seq is monotonic');
  assert.equal(new Set(seqs).size, seqs.length, 'no duplicate sequence values');

  const received: number[] = [];
  for (let i = 0; i < 5; i += 1) {
    const inbound = (await b.next('message.new')) as Record<string, unknown>;
    received.push(inbound['server_seq'] as number);
  }
  assert.deepEqual(received, seqs, 'B observes the server order, not the client order');

  a.disconnect();
  b.disconnect();
});

test('9. a full A->B conversation survives a reconnect of both ends', async () => {
  const a = await world.connected(identityA, 'A');
  const b = await world.connected(identityB, 'B');

  const before = packEnvelope(ratchetA.encrypt('antes de la reconexion'));
  await a.sendAndAwaitAck({ conversationId: CONV, ciphertextBase64: before });
  const firstInbound = (await b.next('message.new')) as Record<string, unknown>;
  assert.equal(
    ratchetB.decrypt(unpackEnvelope(firstInbound['ciphertext'] as string)),
    'antes de la reconexion',
  );

  // Both sides lose the network and come back.
  await a.reconnect({ downtimeMs: 60 });
  await b.reconnect({ downtimeMs: 60 });
  assert.equal(a.handshakes >= 2, true, 'A re-ran the handshake');
  assert.equal(b.handshakes >= 2, true, 'B re-ran the handshake');

  // The conversation continues, and the ratchet is still in sync.
  const after = packEnvelope(ratchetA.encrypt('despues de la reconexion'));
  await a.sendAndAwaitAck({ conversationId: CONV, ciphertextBase64: after });
  const secondInbound = (await b.next('message.new')) as Record<string, unknown>;
  assert.equal(
    ratchetB.decrypt(unpackEnvelope(secondInbound['ciphertext'] as string)),
    'despues de la reconexion',
  );

  a.disconnect();
  b.disconnect();
});

test('10. B cannot decrypt with a foreign ratchet (E2EE is bound to the pair)', async () => {
  // A stranger's session derived from a DIFFERENT X3DH exchange.
  const deviceC = new X3DHDevice();
  const senderAC = x3dhSender(deviceA, deviceC.bundle());
  const strangerSecret = x3dhReceiver(deviceC, {
    senderIdentityRaw: deviceA.identity.publicRaw,
    senderEphemeralRaw: senderAC.ephemeralPublicRaw,
    usedOneTimePreKey: senderAC.usedOneTimePreKey,
  });
  const strangerRatchet = RatchetSession.initReceiver(strangerSecret, deviceC.signedPreKey);

  const body = ratchetA.encrypt('solo para B');
  assert.throws(
    () => strangerRatchet.decrypt(body),
    'a third party must not be able to decrypt A->B traffic',
  );
});

/** Small helper so the suite reads naturally. */
export type { NovaClient };
