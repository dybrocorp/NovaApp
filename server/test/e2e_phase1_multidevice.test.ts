/**
 * FASE 1 — E2E: per-device fan-out and multi-device delivery (§15, §16).
 *
 * A message from device A1 must reach EVERY active device of the peer
 * account, plus the sender's OTHER devices, and each copy must be a
 * distinct ciphertext bound to that device.
 *
 * The properties that matter, and that a naive implementation gets wrong:
 *   * N copies of one message_id must all be delivered (a message-id-only
 *     dedup would swallow all but the first);
 *   * a device-addressed copy must reach ONLY that device;
 *   * a revoked device must receive nothing (§16).
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { World, sleep } from './world.js';
import type { NovaClient, NovaIdentity } from '../src/client/nova_client.js';

const CONV = 'conv-md';
const world = new World();

// Account A with two devices, account B with three.
let a1: NovaIdentity;
let a2: NovaIdentity;
let b1: NovaIdentity;
let b2: NovaIdentity;
let b3: NovaIdentity;

before(async () => {
  await world.start();
  a1 = await world.seedIdentity({ accountId: 'acc-MA', deviceId: 'dev-MA1' });
  a2 = await world.seedIdentity({ accountId: 'acc-MA', deviceId: 'dev-MA2' });
  b1 = await world.seedIdentity({ accountId: 'acc-MB', deviceId: 'dev-MB1' });
  b2 = await world.seedIdentity({ accountId: 'acc-MB', deviceId: 'dev-MB2' });
  b3 = await world.seedIdentity({ accountId: 'acc-MB', deviceId: 'dev-MB3' });
  await world.conversation(CONV, [a1.accountId, b1.accountId]);
});

after(async () => {
  await world.stop();
});

/** Sends one per-device copy and waits for its ack. */
async function sendCopy(
  client: NovaClient,
  messageId: string,
  recipientDeviceId: string,
  ciphertext: string,
): Promise<Record<string, unknown>> {
  client.emitRaw('message.send', {
    message_id: messageId,
    conversation_id: CONV,
    recipient_device_id: recipientDeviceId,
    message_type: 'text',
    envelope_version: 1,
    ciphertext,
    header_type: 'dr.v1',
  });
  for (;;) {
    const ack = (await client.next('message.ack')) as Record<string, unknown>;
    if (ack['recipient_device_id'] === recipientDeviceId) return ack;
  }
}

test('1. one message fans out to every active device of the peer', async () => {
  const sender = await world.connected(a1, 'A1');
  const r1 = await world.connected(b1, 'B1');
  const r2 = await world.connected(b2, 'B2');
  const r3 = await world.connected(b3, 'B3');

  const messageId = `msg-md-${Date.now()}`;
  const targets = [b1, b2, b3];

  // One copy per device, each with its OWN ciphertext.
  for (const target of targets) {
    const ack = await sendCopy(
      sender,
      messageId,
      target.deviceId,
      Buffer.from(`ct-for-${target.deviceId}`).toString('base64'),
    );
    assert.equal(ack['duplicate'], undefined, 'each device copy is accepted');
    assert.equal(typeof ack['server_seq'], 'number');
  }

  // Every device receives exactly its own copy.
  for (const [client, target] of [[r1, b1], [r2, b2], [r3, b3]] as const) {
    const inbound = (await client.next('message.new')) as Record<string, unknown>;
    assert.equal(inbound['message_id'], messageId);
    assert.equal(inbound['recipient_device_id'], target.deviceId);
    assert.equal(
      Buffer.from(inbound['ciphertext'] as string, 'base64').toString(),
      `ct-for-${target.deviceId}`,
      'each device gets the ciphertext encrypted for IT',
    );
  }

  // And nothing extra.
  await r1.expectNone('message.new', 250);
  sender.disconnect();
  r1.disconnect();
  r2.disconnect();
  r3.disconnect();
});

test('2. a device-addressed copy reaches ONLY that device', async () => {
  const sender = await world.connected(a1, 'A1');
  const r1 = await world.connected(b1, 'B1');
  const r2 = await world.connected(b2, 'B2');

  const messageId = `msg-only-${Date.now()}`;
  await sendCopy(sender, messageId, b1.deviceId, Buffer.from('only-b1').toString('base64'));

  const inbound = (await r1.next('message.new')) as Record<string, unknown>;
  assert.equal(inbound['message_id'], messageId);
  // B2 is a member of the same account and conversation but was NOT
  // addressed: it must not receive a ciphertext it cannot decrypt.
  await r2.expectNone('message.new', 350);

  sender.disconnect();
  r1.disconnect();
  r2.disconnect();
});

test('3. the sender\'s OTHER devices receive their own copy (§15)', async () => {
  const sender = await world.connected(a1, 'A1');
  const sibling = await world.connected(a2, 'A2');
  const r1 = await world.connected(b1, 'B1');

  const messageId = `msg-self-${Date.now()}`;
  await sendCopy(sender, messageId, b1.deviceId, Buffer.from('to-b1').toString('base64'));
  await sendCopy(sender, messageId, a2.deviceId, Buffer.from('to-a2').toString('base64'));

  const onPeer = (await r1.next('message.new')) as Record<string, unknown>;
  assert.equal(onPeer['recipient_device_id'], b1.deviceId);

  const onSibling = (await sibling.next('message.new')) as Record<string, unknown>;
  assert.equal(onSibling['recipient_device_id'], a2.deviceId);
  assert.equal(
    onSibling['sender_account_id'],
    a1.accountId,
    'the sibling sees it as coming from its own account',
  );

  // The sending device gets only its acks, never its own fan-out.
  await sender.expectNone('message.new', 250);

  sender.disconnect();
  sibling.disconnect();
  r1.disconnect();
});

test('4. per-device copies keep idempotency PER DEVICE', async () => {
  const sender = await world.connected(a1, 'A1');
  const r1 = await world.connected(b1, 'B1');

  const messageId = `msg-idem-md-${Date.now()}`;
  const ciphertext = Buffer.from('idem').toString('base64');

  const first = await sendCopy(sender, messageId, b1.deviceId, ciphertext);
  assert.equal(first['duplicate'], undefined);

  // Same message_id AND same device: a genuine retransmission.
  const retry = await sendCopy(sender, messageId, b1.deviceId, ciphertext);
  assert.equal(retry['duplicate'], true, 'same (message, device) is idempotent');
  assert.equal(retry['server_seq'], first['server_seq'], 'original seq replayed');

  await r1.next('message.new');
  await r1.expectNone('message.new', 300);

  sender.disconnect();
  r1.disconnect();
});

test('5. a revoked device receives nothing (§16)', async () => {
  const doomed = await world.seedIdentity({ accountId: 'acc-MB', deviceId: 'dev-MB-doomed' });
  const sender = await world.connected(a1, 'A1');
  const victim = await world.connected(doomed, 'doomed');

  await world.server.adminRevokeDevice(doomed.deviceId);
  await victim.next('device.revoked');
  await victim.next('disconnect');
  await sleep(60);

  // The server still accepts the envelope (it cannot know the sender's
  // device list is stale), but the revoked device is disconnected and
  // can never authenticate again to collect it.
  const messageId = `msg-revoked-${Date.now()}`;
  await sendCopy(sender, messageId, doomed.deviceId, Buffer.from('x').toString('base64'));

  const retry = world.client(doomed, 'doomed-retry');
  retry.connect();
  await assert.rejects(
    () => retry.authenticate(),
    /auth\.failure/,
    'a revoked device can never come back for its copies',
  );

  retry.disconnect();
  sender.disconnect();
  victim.disconnect();
});

test('6. sender_device_id cannot be spoofed on a per-device copy', async () => {
  const sender = await world.connected(a1, 'A1');
  sender.emitRaw('message.send', {
    message_id: `msg-spoof-md-${Date.now()}`,
    conversation_id: CONV,
    sender_device_id: b1.deviceId, // claiming to be the peer's device
    recipient_device_id: b1.deviceId,
    ciphertext: Buffer.from('spoof').toString('base64'),
    header_type: 'dr.v1',
  });
  const error = (await sender.next('system.error')) as Record<string, unknown>;
  assert.equal(error['code'], 'PAYLOAD_INVALID');
  sender.disconnect();
});

test('7. per-device copies are recoverable through sync', async () => {
  const sender = await world.connected(a1, 'A1');
  const offline = world.client(b2, 'B2-offline');
  offline.connect();
  await offline.authenticate();
  offline.dropConnection();

  const messageId = `msg-sync-md-${Date.now()}`;
  await sendCopy(
    sender,
    messageId,
    b2.deviceId,
    Buffer.from('while-offline').toString('base64'),
  );

  offline.connect();
  await offline.authenticate();
  const response = await offline.sync(CONV);
  const events = (response['events'] as Array<Record<string, unknown>>).filter(
    (event) => event['type'] === 'message.new' && event['message_id'] === messageId,
  );
  assert.equal(events.length, 1, 'the device copy is replayed exactly once');
  assert.equal(events[0]!['recipient_device_id'], b2.deviceId);

  sender.disconnect();
  offline.disconnect();
});
