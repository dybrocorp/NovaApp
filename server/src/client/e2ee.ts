/**
 * Client-side E2EE for the FASE 0.5 harness — X3DH + Double Ratchet.
 *
 * This is a faithful port of the app's crypto contract
 * (`lib/core/services/x3dh_service.dart`,
 *  `lib/core/services/double_ratchet_service.dart`) using node:crypto, so
 * NOVA CLIENT A and NOVA CLIENT B perform REAL end-to-end encryption:
 *
 *   X3DH        4 DH (or 3 without OPK) -> HKDF-SHA256 -> shared secret
 *   Ratchet     RK/CK via HKDF-SHA256(salt=RK, ikm=DH)
 *   Chain       MK = HMAC-SHA256(CK, 0x01); CK' = HMAC-SHA256(CK, 0x02)
 *   AEAD        AES-256-GCM, AAD = ratchet_pub || msg_num || prev_chain_len
 *
 * The ONLY thing that ever leaves a client is the AEAD ciphertext blob
 * (base64). Keys never leave the process; plaintext never touches a wire
 * field. The realtime server has no key material and cannot decrypt.
 *
 * Scope note: this is the harness's E2EE, used to prove the transport
 * carries opaque ciphertext end to end. It is NOT a re-implementation of
 * the app's storage/session persistence, and it has not been through an
 * independent cryptographic audit.
 */
import {
  createCipheriv,
  createDecipheriv,
  createHmac,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  randomBytes,
  type KeyObject,
} from 'node:crypto';

// ---------------------------------------------------------------------
// X25519 helpers
// ---------------------------------------------------------------------

export interface X25519KeyPair {
  privateKey: KeyObject;
  publicKey: KeyObject;
  publicRaw: Buffer;
}

export function generateX25519(): X25519KeyPair {
  const { privateKey, publicKey } = generateKeyPairSync('x25519');
  return {
    privateKey,
    publicKey,
    publicRaw: Buffer.from(publicKey.export({ type: 'spki', format: 'der' })).subarray(-32),
  };
}

const X25519_SPKI_PREFIX = Buffer.from('302a300506032b656e032100', 'hex');
const X25519_PKCS8_PREFIX = Buffer.from('302e020100300506032b656e04220420', 'hex');

export function x25519PublicFromRaw(raw: Buffer): KeyObject {
  if (raw.length !== 32) throw new TypeError('x25519 public key must be 32 bytes');
  return createPublicKey({
    key: Buffer.concat([X25519_SPKI_PREFIX, raw]),
    format: 'der',
    type: 'spki',
  });
}

export function x25519PrivateFromRaw(raw: Buffer): KeyObject {
  if (raw.length !== 32) throw new TypeError('x25519 private key must be 32 bytes');
  return createPrivateKey({
    key: Buffer.concat([X25519_PKCS8_PREFIX, raw]),
    format: 'der',
    type: 'pkcs8',
  });
}

function dh(privateKey: KeyObject, publicKey: KeyObject): Buffer {
  return diffieHellman({ privateKey, publicKey });
}

function hkdf(ikm: Buffer, salt: Buffer, length: number, info = ''): Buffer {
  return Buffer.from(hkdfSync('sha256', ikm, salt, Buffer.from(info, 'utf8'), length));
}

// ---------------------------------------------------------------------
// X3DH
// ---------------------------------------------------------------------

/** Published bundle: what a peer fetches to start a session. */
export interface PreKeyBundle {
  identityKeyRaw: Buffer; // X25519 identity public key (IK)
  signedPreKeyRaw: Buffer; // SPK public
  oneTimePreKeyRaw?: Buffer; // OPK public (optional, consumed once)
}

/** A device's long-lived + pre-key material. */
export class X3DHDevice {
  readonly identity = generateX25519();
  readonly signedPreKey = generateX25519();
  readonly oneTimePreKey = generateX25519();

  bundle(): PreKeyBundle {
    return {
      identityKeyRaw: this.identity.publicRaw,
      signedPreKeyRaw: this.signedPreKey.publicRaw,
      oneTimePreKeyRaw: this.oneTimePreKey.publicRaw,
    };
  }
}

export interface X3DHSenderResult {
  sharedSecret: Buffer;
  ephemeralPublicRaw: Buffer;
  usedOneTimePreKey: boolean;
}

/** Alice: DH1..DH4 -> HKDF -> SK. */
export function x3dhSender(me: X3DHDevice, theirBundle: PreKeyBundle): X3DHSenderResult {
  const ephemeral = generateX25519();
  const theirIk = x25519PublicFromRaw(theirBundle.identityKeyRaw);
  const theirSpk = x25519PublicFromRaw(theirBundle.signedPreKeyRaw);

  const dh1 = dh(me.identity.privateKey, theirSpk); // IK_A x SPK_B
  const dh2 = dh(ephemeral.privateKey, theirIk); // EK_A x IK_B
  const dh3 = dh(ephemeral.privateKey, theirSpk); // EK_A x SPK_B
  const parts = [dh1, dh2, dh3];
  let usedOneTimePreKey = false;
  if (theirBundle.oneTimePreKeyRaw) {
    const theirOpk = x25519PublicFromRaw(theirBundle.oneTimePreKeyRaw);
    parts.push(dh(ephemeral.privateKey, theirOpk)); // EK_A x OPK_B
    usedOneTimePreKey = true;
  }
  const sharedSecret = hkdf(Buffer.concat(parts), Buffer.alloc(32), 32, 'NovaApp-X3DH-v1');
  return { sharedSecret, ephemeralPublicRaw: ephemeral.publicRaw, usedOneTimePreKey };
}

/** Bob: mirrors the sender's DHs with his private halves. */
export function x3dhReceiver(
  me: X3DHDevice,
  input: {
    senderIdentityRaw: Buffer;
    senderEphemeralRaw: Buffer;
    usedOneTimePreKey: boolean;
  },
): Buffer {
  const theirIk = x25519PublicFromRaw(input.senderIdentityRaw);
  const theirEk = x25519PublicFromRaw(input.senderEphemeralRaw);

  const dh1 = dh(me.signedPreKey.privateKey, theirIk);
  const dh2 = dh(me.identity.privateKey, theirEk);
  const dh3 = dh(me.signedPreKey.privateKey, theirEk);
  const parts = [dh1, dh2, dh3];
  if (input.usedOneTimePreKey) {
    parts.push(dh(me.oneTimePreKey.privateKey, theirEk));
  }
  return hkdf(Buffer.concat(parts), Buffer.alloc(32), 32, 'NovaApp-X3DH-v1');
}

// ---------------------------------------------------------------------
// Double Ratchet
// ---------------------------------------------------------------------

const MAX_SKIPPED_KEYS = 2000;

/** The wire body — this is what gets base64'd into `ciphertext`. */
export interface RatchetMessage {
  ciphertext: string;
  nonce: string;
  mac: string;
  message_number: number;
  previous_chain_length: number;
  ratchet_public_key: string;
}

function kdfRootKey(rootKey: Buffer, dhOut: Buffer): { rootKey: Buffer; chainKey: Buffer } {
  const derived = hkdf(dhOut, rootKey, 64, 'NovaApp-Ratchet-v1');
  return { rootKey: derived.subarray(0, 32), chainKey: derived.subarray(32, 64) };
}

function messageKey(chainKey: Buffer): Buffer {
  return createHmac('sha256', chainKey).update(Buffer.from([0x01])).digest();
}

function advanceChain(chainKey: Buffer): Buffer {
  return createHmac('sha256', chainKey).update(Buffer.from([0x02])).digest();
}

function buildAad(ratchetPubB64: string, msgNum: number, prevChainLen: number): Buffer {
  const counters = Buffer.alloc(8);
  counters.writeUInt32LE(msgNum >>> 0, 0);
  counters.writeUInt32LE(prevChainLen >>> 0, 4);
  return Buffer.concat([Buffer.from(ratchetPubB64, 'utf8'), counters]);
}

export class RatchetSession {
  private rootKey: Buffer;
  private sendingChainKey: Buffer | null = null;
  private receivingChainKey: Buffer | null = null;
  private myRatchet: X25519KeyPair;
  private theirRatchetRaw: Buffer | null = null;
  private sendCount = 0;
  private receiveCount = 0;
  private previousSendCount = 0;
  private readonly skipped = new Map<string, Buffer>();
  private readonly decrypted = new Set<string>();

  private constructor(rootKey: Buffer, myRatchet: X25519KeyPair) {
    this.rootKey = rootKey;
    this.myRatchet = myRatchet;
  }

  /** Alice: initialises the sending chain against Bob's SPK. */
  static initSender(sharedSecret: Buffer, theirRatchetRaw: Buffer): RatchetSession {
    const myRatchet = generateX25519();
    const session = new RatchetSession(sharedSecret, myRatchet);
    const dhOut = dh(myRatchet.privateKey, x25519PublicFromRaw(theirRatchetRaw));
    const derived = kdfRootKey(sharedSecret, dhOut);
    session.rootKey = derived.rootKey;
    session.sendingChainKey = derived.chainKey;
    session.theirRatchetRaw = theirRatchetRaw;
    return session;
  }

  /** Bob: holds his SPK pair as the initial ratchet key, no chains yet. */
  static initReceiver(sharedSecret: Buffer, myRatchet: X25519KeyPair): RatchetSession {
    return new RatchetSession(sharedSecret, myRatchet);
  }

  /** Encrypts plaintext. Returns the opaque wire body. */
  encrypt(plaintext: string): RatchetMessage {
    if (!this.sendingChainKey) throw new Error('no sending chain — cannot encrypt');
    const mk = messageKey(this.sendingChainKey);
    this.sendingChainKey = advanceChain(this.sendingChainKey);
    const ratchetPubB64 = this.myRatchet.publicRaw.toString('base64');
    const aad = buildAad(ratchetPubB64, this.sendCount, this.previousSendCount);
    const nonce = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', mk, nonce);
    cipher.setAAD(aad);
    const ciphertext = Buffer.concat([cipher.update(Buffer.from(plaintext, 'utf8')), cipher.final()]);
    const body: RatchetMessage = {
      ciphertext: ciphertext.toString('base64'),
      nonce: nonce.toString('base64'),
      mac: cipher.getAuthTag().toString('base64'),
      message_number: this.sendCount,
      previous_chain_length: this.previousSendCount,
      ratchet_public_key: ratchetPubB64,
    };
    this.sendCount += 1;
    return body;
  }

  /** Decrypts a wire body. Handles out-of-order and DH ratchet steps. */
  decrypt(body: RatchetMessage): string {
    const theirRaw = Buffer.from(body.ratchet_public_key, 'base64');
    const isNewKey =
      body.ratchet_public_key.length > 0 &&
      (this.theirRatchetRaw === null || !this.theirRatchetRaw.equals(theirRaw));

    if (isNewKey) {
      if (this.receivingChainKey) this.dhRatchetStep(theirRaw);
      else this.initReceiverChains(theirRaw);
    }

    const theirKeyB64 = (this.theirRatchetRaw ?? Buffer.alloc(0)).toString('base64');
    const replayKey = `${body.message_number}-${theirKeyB64}`;
    if (this.decrypted.has(replayKey)) {
      throw new Error(`message #${body.message_number} already decrypted (replay)`);
    }

    const skippedKey = this.skipped.get(replayKey);
    if (skippedKey) {
      this.skipped.delete(replayKey);
      const plaintext = this.open(skippedKey, body);
      this.decrypted.add(replayKey);
      return plaintext;
    }

    while (this.receiveCount < body.message_number) {
      if (!this.receivingChainKey) throw new Error('no receiving chain');
      const mk = messageKey(this.receivingChainKey);
      this.skipped.set(`${this.receiveCount}-${theirKeyB64}`, mk);
      this.receivingChainKey = advanceChain(this.receivingChainKey);
      this.receiveCount += 1;
      if (this.skipped.size > MAX_SKIPPED_KEYS) {
        throw new Error(`skipped message keys limit exceeded (${MAX_SKIPPED_KEYS})`);
      }
    }

    if (!this.receivingChainKey) throw new Error('no receiving chain');
    const mk = messageKey(this.receivingChainKey);
    this.receivingChainKey = advanceChain(this.receivingChainKey);
    this.receiveCount += 1;
    const plaintext = this.open(mk, body);
    this.decrypted.add(replayKey);
    return plaintext;
  }

  private open(mk: Buffer, body: RatchetMessage): string {
    const aad = buildAad(
      body.ratchet_public_key,
      body.message_number,
      body.previous_chain_length,
    );
    const decipher = createDecipheriv('aes-256-gcm', mk, Buffer.from(body.nonce, 'base64'));
    decipher.setAAD(aad);
    decipher.setAuthTag(Buffer.from(body.mac, 'base64'));
    const plaintext = Buffer.concat([
      decipher.update(Buffer.from(body.ciphertext, 'base64')),
      decipher.final(),
    ]);
    return plaintext.toString('utf8');
  }

  /** Bob's first receive: derive the receiving chain with his SPK pair. */
  private initReceiverChains(theirRaw: Buffer): void {
    const theirKey = x25519PublicFromRaw(theirRaw);
    const recv = kdfRootKey(this.rootKey, dh(this.myRatchet.privateKey, theirKey));
    this.rootKey = recv.rootKey;
    this.receivingChainKey = recv.chainKey;
    this.theirRatchetRaw = theirRaw;
    this.previousSendCount = 0;
    this.sendCount = 0;
    this.receiveCount = 0;

    const newPair = generateX25519();
    const send = kdfRootKey(this.rootKey, dh(newPair.privateKey, theirKey));
    this.rootKey = send.rootKey;
    this.sendingChainKey = send.chainKey;
    this.myRatchet = newPair;
  }

  /** Standard DH ratchet step on seeing a new peer ratchet key. */
  private dhRatchetStep(theirRaw: Buffer): void {
    const theirKey = x25519PublicFromRaw(theirRaw);
    const recv = kdfRootKey(this.rootKey, dh(this.myRatchet.privateKey, theirKey));
    this.rootKey = recv.rootKey;
    this.receivingChainKey = recv.chainKey;
    this.previousSendCount = this.sendCount;
    this.sendCount = 0;
    this.receiveCount = 0;
    this.theirRatchetRaw = theirRaw;

    const newPair = generateX25519();
    const send = kdfRootKey(this.rootKey, dh(newPair.privateKey, theirKey));
    this.rootKey = send.rootKey;
    this.sendingChainKey = send.chainKey;
    this.myRatchet = newPair;
  }
}

// ---------------------------------------------------------------------
// Envelope helpers (what actually travels on the socket)
// ---------------------------------------------------------------------

/** Serialises a ratchet body into the opaque base64 blob sent as `ciphertext`. */
export function packEnvelope(body: RatchetMessage): string {
  return Buffer.from(JSON.stringify(body), 'utf8').toString('base64');
}

export function unpackEnvelope(ciphertextBase64: string): RatchetMessage {
  return JSON.parse(Buffer.from(ciphertextBase64, 'base64').toString('utf8')) as RatchetMessage;
}

/** A ready-to-use pair of ratchet sessions sharing an X3DH secret. */
export function establishSessions(): {
  alice: RatchetSession;
  bob: RatchetSession;
  aliceDevice: X3DHDevice;
  bobDevice: X3DHDevice;
} {
  const aliceDevice = new X3DHDevice();
  const bobDevice = new X3DHDevice();
  const sender = x3dhSender(aliceDevice, bobDevice.bundle());
  const bobSecret = x3dhReceiver(bobDevice, {
    senderIdentityRaw: aliceDevice.identity.publicRaw,
    senderEphemeralRaw: sender.ephemeralPublicRaw,
    usedOneTimePreKey: sender.usedOneTimePreKey,
  });
  if (!sender.sharedSecret.equals(bobSecret)) {
    throw new Error('X3DH secrets diverged — key agreement is broken');
  }
  return {
    alice: RatchetSession.initSender(sender.sharedSecret, bobDevice.signedPreKey.publicRaw),
    bob: RatchetSession.initReceiver(bobSecret, bobDevice.signedPreKey),
    aliceDevice,
    bobDevice,
  };
}
