/**
 * Canonical signed message + Ed25519 verification for the `auth.*`
 * handshake. 1:1 port of `lib/core/socket/auth/auth_signer.dart` (PASO 4).
 *
 * Canonical message (v1) — the signature covers ALL identity claims plus
 * the challenge, so a valid signature for one device can never be replayed
 * as another device:
 *
 *   NOVA_AUTH_v1|<account_id>|<device_id>|<nova_id>|<challenge_id>|<challenge>
 *
 * The server verifies against the REGISTERED Ed25519 public key of
 * (account_id, device_id) — never against a key sent by the client.
 */
import { createPublicKey, verify as cryptoVerify } from 'node:crypto';

export const CANONICAL_PREFIX = 'NOVA_AUTH_v1';

export function canonicalMessage(input: {
  accountId: string;
  deviceId: string;
  novaId: string;
  challengeId: string;
  challengeBase64: string;
}): string {
  return [
    CANONICAL_PREFIX,
    input.accountId,
    input.deviceId,
    input.novaId,
    input.challengeId,
    input.challengeBase64,
  ].join('|');
}

/** Raw 32-byte Ed25519 public key -> KeyObject. */
export function ed25519PublicKeyFromRaw(raw: Uint8Array) {
  // DER SPKI wrapper for a raw Ed25519 public key (RFC 8410):
  // 302a300506032b6570032100 || <32 bytes>
  if (raw.length !== 32) {
    throw new TypeError('ed25519 public key must be exactly 32 bytes');
  }
  const der = Buffer.concat([
    Buffer.from('302a300506032b6570032100', 'hex'),
    Buffer.from(raw),
  ]);
  return createPublicKey({ key: der, format: 'der', type: 'spki' });
}

/**
 * Reference verification mirrored from the Dart `AuthSigner`:
 * verifies `signatureBase64` over the canonical message using the
 * REGISTERED public key. Malformed base64/signature => false, never a
 * crash, never a thrown error.
 */
export function verifyAuthSignature(input: {
  accountId: string;
  deviceId: string;
  novaId: string;
  challengeId: string;
  challengeBase64: string;
  signatureBase64: string;
  registeredPublicKey: Uint8Array;
}): boolean {
  const message = canonicalMessage({
    accountId: input.accountId,
    deviceId: input.deviceId,
    novaId: input.novaId,
    challengeId: input.challengeId,
    challengeBase64: input.challengeBase64,
  });
  try {
    const signature = Buffer.from(input.signatureBase64, 'base64');
    if (signature.length !== 64) return false;
    const publicKey = ed25519PublicKeyFromRaw(input.registeredPublicKey);
    return cryptoVerify(null, Buffer.from(message, 'utf8'), publicKey, signature);
  } catch {
    return false;
  }
}
