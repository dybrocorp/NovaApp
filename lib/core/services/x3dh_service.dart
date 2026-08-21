import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/services/logger_service.dart';

/// X3DH (Extended Triple Diffie-Hellman) key agreement protocol.
///
/// Provides forward secrecy and deniability for initial key establishment.
///
/// Key Hierarchy:
///   IK  — Identity Key (Ed25519, long-lived, one per account)
///   SPK — Signed Pre-Key (X25519, rotated periodically)
///   OPK — One-Time Pre-Key (X25519, consumed once)
///
/// Protocol flow (Alice → Bob):
///   1. Fetch Bob's key bundle: {IK_B, SPK_B, OPK_B}
///   2. Generate ephemeral key pair: EK_A
///   3. Compute 4 DH shared secrets:
///      DH1 = DH(IK_A, SPK_B)
///      DH2 = DH(EK_A, IK_B)
///      DH3 = DH(EK_A, SPK_B)
///      DH4 = DH(EK_A, OPK_B)
///   4. SK = HKDF(DH1 || DH2 || DH3 || DH4)
///
/// Bob reverses the process using his private keys.

/// Result of an X3DH key agreement.
/// Contains the shared secret and metadata needed by the sender.
class X3DHResult {
  final List<int> sharedSecret;
  final String ephemeralPublicKey; // base64, sent to Bob
  final String? oneTimePreKeyId; // which OPK was consumed

  X3DHResult({
    required this.sharedSecret,
    required this.ephemeralPublicKey,
    this.oneTimePreKeyId,
  });
}

/// Result of a key bundle to publish to the server.
class X3DHKeyBundle {
  final String identityKeyPublic; // base64
  final String signedPreKeyPublic; // base64
  final String signedPreKeySignature; // base64
  final List<String> oneTimePreKeysPublic; // list of base64
  final int signedPreKeyId;

  X3DHKeyBundle({
    required this.identityKeyPublic,
    required this.signedPreKeyPublic,
    required this.signedPreKeySignature,
    required this.oneTimePreKeysPublic,
    required this.signedPreKeyId,
  });
}

class X3DHService {
  final _ed25519 = Ed25519();
  final _x25519 = X25519();
  final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// Generates a complete X3DH key bundle for a new device.
  Future<X3DHKeyBundle> generateKeyBundle({
    int opkCount = 10,
    int spkId = 1,
  }) async {
    // Identity Key (Ed25519)
    final ik = await _ed25519.newKeyPair();
    final ikPublic = await ik.extractPublicKey();

    // Signed Pre-Key (X25519)
    final spk = await _x25519.newKeyPair();
    final spkPublic = await spk.extractPublicKey();

    // Sign SPK with IK
    final spkBytes = spkPublic.bytes;
    final signature = await _ed25519.sign(spkBytes, keyPair: ik);

    // One-Time Pre-Keys
    final opks = <String>[];
    for (int i = 0; i < opkCount; i++) {
      final opk = await _x25519.newKeyPair();
      final opkPublic = await opk.extractPublicKey();
      opks.add(base64Encode(opkPublic.bytes));
    }

    return X3DHKeyBundle(
      identityKeyPublic: base64Encode(ikPublic.bytes),
      signedPreKeyPublic: base64Encode(spkPublic.bytes),
      signedPreKeySignature: base64Encode(signature.bytes),
      oneTimePreKeysPublic: opks,
      signedPreKeyId: spkId,
    );
  }

  /// Performs X3DH as the sender (Alice).
  ///
  /// [myIdentityKey] — sender's Ed25519 key pair
  /// [recipientBundle] — fetched from server: {identity_key, signed_pre_key, one_time_pre_key?}
  ///
  /// Returns [X3DHResult] with the shared secret and ephemeral public key.
  Future<X3DHResult> performX3DHAsSender({
    required SimpleKeyPair myIdentityKey,
    required Map<String, String> recipientBundle,
  }) async {
    final ikA = await myIdentityKey.extractPublicKey();
    final ikBBytes = base64Decode(recipientBundle['identity_key']!);
    final ikB = SimplePublicKey(ikBBytes, type: KeyPairType.x25519);

    final spkBBytes = base64Decode(recipientBundle['signed_pre_key']!);
    final spkB = SimplePublicKey(spkBBytes, type: KeyPairType.x25519);

    // Verify SPK signature
    final signatureBytes =
        base64Decode(recipientBundle['signed_pre_key_signature'] ?? '');
    if (signatureBytes.isNotEmpty) {
      try {
        final valid = await _ed25519.verify(
          spkBBytes,
          signature: Signature(signatureBytes, publicKey: ikB),
        );
        if (!valid) {
          LoggerService.warning('SPK signature verification failed',
              tag: 'X3DH');
        }
      } catch (e) {
        LoggerService.warning('SPK signature check error: $e', tag: 'X3DH');
      }
    }

    // Generate ephemeral key pair
    final ek = await _x25519.newKeyPair();
    final ekPublic = await ek.extractPublicKey();

    // DH1 = DH(IK_A, SPK_B)
    final dh1 = await _x25519.sharedSecretKey(
        keyPair: myIdentityKey, remotePublicKey: spkB);
    // DH2 = DH(EK_A, IK_B)
    final dh2 =
        await _x25519.sharedSecretKey(keyPair: ek, remotePublicKey: ikB);
    // DH3 = DH(EK_A, SPK_B)
    final dh3 =
        await _x25519.sharedSecretKey(keyPair: ek, remotePublicKey: spkB);

    // Combine DH outputs
    final dh1Bytes = await dh1.extractBytes();
    final dh2Bytes = await dh2.extractBytes();
    final dh3Bytes = await dh3.extractBytes();

    var combined =
        Uint8List.fromList([...dh1Bytes, ...dh2Bytes, ...dh3Bytes]);

    // DH4 = DH(EK_A, OPK_B) — optional
    final opkB64 = recipientBundle['one_time_pre_key'];
    String? consumedOpkId;
    if (opkB64 != null && opkB64.isNotEmpty) {
      final opkB =
          SimplePublicKey(base64Decode(opkB64), type: KeyPairType.x25519);
      final dh4 =
          await _x25519.sharedSecretKey(keyPair: ek, remotePublicKey: opkB);
      final dh4Bytes = await dh4.extractBytes();
      combined = Uint8List.fromList([...combined, ...dh4Bytes]);
      consumedOpkId = opkB64;
    }

    // SK = HKDF(combined)
    final sk = await _hkdf.deriveKey(secretKey: SecretKey(combined));

    LoggerService.info('X3DH completed (sender), shared secret derived',
        tag: 'X3DH');

    return X3DHResult(
      sharedSecret: await sk.extractBytes(),
      ephemeralPublicKey: base64Encode(ekPublic.bytes),
      oneTimePreKeyId: consumedOpkId,
    );
  }

  /// Performs X3DH as the receiver (Bob).
  ///
  /// [myIdentityKey] — receiver's Ed25519 key pair
  /// [mySignedPreKey] — receiver's signed pre-key pair
  /// [myOneTimePreKey] — receiver's one-time pre-key pair (nullable)
  /// [ephemeralPublicKeyBase64] — sender's ephemeral public key (base64)
  /// [senderIdentityKeyBase64] — sender's identity key (base64)
  ///
  /// Returns the shared secret (same as sender's).
  Future<List<int>> performX3DHAsReceiver({
    required SimpleKeyPair myIdentityKey,
    required SimpleKeyPair mySignedPreKey,
    SimpleKeyPair? myOneTimePreKey,
    required String ephemeralPublicKeyBase64,
    required String senderIdentityKeyBase64,
  }) async {
    final ikA = SimplePublicKey(base64Decode(senderIdentityKeyBase64),
        type: KeyPairType.x25519);
    final ekA = SimplePublicKey(base64Decode(ephemeralPublicKeyBase64),
        type: KeyPairType.x25519);

    // DH1 = DH(SPK_B, IK_A)
    final dh1 = await _x25519.sharedSecretKey(
        keyPair: mySignedPreKey, remotePublicKey: ikA);
    // DH2 = DH(IK_B, EK_A)
    final dh2 = await _x25519.sharedSecretKey(
        keyPair: myIdentityKey, remotePublicKey: ekA);
    // DH3 = DH(SPK_B, EK_A)
    final dh3 = await _x25519.sharedSecretKey(
        keyPair: mySignedPreKey, remotePublicKey: ekA);

    final dh1Bytes = await dh1.extractBytes();
    final dh2Bytes = await dh2.extractBytes();
    final dh3Bytes = await dh3.extractBytes();

    var combined =
        Uint8List.fromList([...dh1Bytes, ...dh2Bytes, ...dh3Bytes]);

    // DH4 = DH(OPK_B, EK_A) — optional
    if (myOneTimePreKey != null) {
      final dh4 = await _x25519.sharedSecretKey(
          keyPair: myOneTimePreKey, remotePublicKey: ekA);
      final dh4Bytes = await dh4.extractBytes();
      combined = Uint8List.fromList([...combined, ...dh4Bytes]);
    }

    // SK = HKDF(combined)
    final sk = await _hkdf.deriveKey(secretKey: SecretKey(combined));

    LoggerService.info('X3DH completed (receiver), shared secret derived',
        tag: 'X3DH');
    return sk.extractBytes();
  }
}

final x3dhServiceProvider = Provider((ref) => X3DHService());
