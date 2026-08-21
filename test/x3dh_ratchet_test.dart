import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:novaapp/core/services/x3dh_service.dart';
import 'package:novaapp/core/services/double_ratchet_service.dart';

void main() {
  final x3dh = X3DHService();
  final ratchet = DoubleRatchetService();

  Future<({SimpleKeyPair ed25519, SimpleKeyPair x25519})>
      _generateIdentityKeyPair() async {
    final seedBytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final ed = await Ed25519().newKeyPairFromSeed(seedBytes);
    final x25 = await X25519().newKeyPairFromSeed(seedBytes);
    return (ed25519: ed, x25519: x25);
  }

  group('X3DH - Key Bundle Generation', () {
    test('generateKeyBundle produces Ed25519 + X25519 identity keys', () async {
      final bundle = await x3dh.generateKeyBundle();
      expect(bundle.identityKeyPublic, isNotEmpty);
      expect(bundle.x25519IdentityKeyPublic, isNotEmpty);
      expect(bundle.signedPreKeyPublic, isNotEmpty);
      expect(bundle.signedPreKeySignature, isNotEmpty);
      expect(bundle.oneTimePreKeysPublic.length, equals(10));
      expect(bundle.signedPreKeyId, equals(1));
    });
  });

  group('X3DH - Shared Secret Equality', () {
    test('Alice and Bob derive the same shared secret (with OPK)', () async {
      final bobIdentity = await _generateIdentityKeyPair();
      final bobSPK = await X25519().newKeyPair();
      final bobOPK = await X25519().newKeyPair();

      final bobSPKPublic = await bobSPK.extractPublicKey();
      final bobOPKPublic = await bobOPK.extractPublicKey();
      final bobX25519Public = await bobIdentity.x25519.extractPublicKey();

      final spkSignature = await Ed25519().sign(
        bobSPKPublic.bytes,
        keyPair: bobIdentity.ed25519,
      );

      final recipientBundle = {
        'x25519_identity_key': base64Encode(bobX25519Public.bytes),
        'signed_pre_key': base64Encode(bobSPKPublic.bytes),
        'signed_pre_key_signature': base64Encode(spkSignature.bytes),
        'one_time_pre_key': base64Encode(bobOPKPublic.bytes),
      };

      final aliceIdentity = await _generateIdentityKeyPair();
      final aliceResult = await x3dh.performX3DHAsSender(
        myEd25519IdentityKey: aliceIdentity.ed25519,
        myX25519IdentityKey: aliceIdentity.x25519,
        recipientBundle: recipientBundle,
      );

      final aliceX25519Public = await aliceIdentity.x25519.extractPublicKey();
      final bobSecret = await x3dh.performX3DHAsReceiver(
        myEd25519IdentityKey: bobIdentity.ed25519,
        myX25519IdentityKey: bobIdentity.x25519,
        mySignedPreKey: bobSPK,
        myOneTimePreKey: bobOPK,
        ephemeralPublicKeyBase64: aliceResult.ephemeralPublicKey,
        senderX25519IdentityKeyBase64: base64Encode(aliceX25519Public.bytes),
      );

      expect(aliceResult.sharedSecret, equals(bobSecret));
      expect(aliceResult.sharedSecret.length, equals(32));
      expect(aliceResult.oneTimePreKeyId, isNotNull);
    });

    test('Alice and Bob derive the same secret without OPK', () async {
      final bobIdentity = await _generateIdentityKeyPair();
      final bobSPK = await X25519().newKeyPair();

      final bobSPKPublic = await bobSPK.extractPublicKey();
      final bobX25519Public = await bobIdentity.x25519.extractPublicKey();

      final spkSignature = await Ed25519().sign(
        bobSPKPublic.bytes,
        keyPair: bobIdentity.ed25519,
      );

      final recipientBundle = {
        'x25519_identity_key': base64Encode(bobX25519Public.bytes),
        'signed_pre_key': base64Encode(bobSPKPublic.bytes),
        'signed_pre_key_signature': base64Encode(spkSignature.bytes),
      };

      final aliceIdentity = await _generateIdentityKeyPair();
      final aliceResult = await x3dh.performX3DHAsSender(
        myEd25519IdentityKey: aliceIdentity.ed25519,
        myX25519IdentityKey: aliceIdentity.x25519,
        recipientBundle: recipientBundle,
      );

      final aliceX25519Public = await aliceIdentity.x25519.extractPublicKey();
      final bobSecret = await x3dh.performX3DHAsReceiver(
        myEd25519IdentityKey: bobIdentity.ed25519,
        myX25519IdentityKey: bobIdentity.x25519,
        mySignedPreKey: bobSPK,
        ephemeralPublicKeyBase64: aliceResult.ephemeralPublicKey,
        senderX25519IdentityKeyBase64: base64Encode(aliceX25519Public.bytes),
      );

      expect(aliceResult.sharedSecret, equals(bobSecret));
      expect(aliceResult.oneTimePreKeyId, isNull);
    });

    test('different sender keys produce different shared secrets', () async {
      final bobIdentity = await _generateIdentityKeyPair();
      final bobSPK = await X25519().newKeyPair();
      final bobSPKPublic = await bobSPK.extractPublicKey();
      final bobX25519Public = await bobIdentity.x25519.extractPublicKey();
      final spkSignature = await Ed25519().sign(
        bobSPKPublic.bytes, keyPair: bobIdentity.ed25519,
      );

      final recipientBundle = {
        'x25519_identity_key': base64Encode(bobX25519Public.bytes),
        'signed_pre_key': base64Encode(bobSPKPublic.bytes),
        'signed_pre_key_signature': base64Encode(spkSignature.bytes),
      };

      final alice1 = await _generateIdentityKeyPair();
      final alice2 = await _generateIdentityKeyPair();

      final result1 = await x3dh.performX3DHAsSender(
        myEd25519IdentityKey: alice1.ed25519,
        myX25519IdentityKey: alice1.x25519,
        recipientBundle: recipientBundle,
      );
      final result2 = await x3dh.performX3DHAsSender(
        myEd25519IdentityKey: alice2.ed25519,
        myX25519IdentityKey: alice2.x25519,
        recipientBundle: recipientBundle,
      );

      expect(result1.sharedSecret, isNot(equals(result2.sharedSecret)));
    });
  });

  group('X3DH - Signature Verification', () {
    test('SPK signature mismatch does not block (warning only)', () async {
      final bobIdentity = await _generateIdentityKeyPair();
      final bobSPK = await X25519().newKeyPair();
      final bobSPKPublic = await bobSPK.extractPublicKey();
      final bobX25519Public = await bobIdentity.x25519.extractPublicKey();

      final wrongKey = await Ed25519().newKeyPair();
      final wrongSig = await Ed25519().sign(
        bobSPKPublic.bytes, keyPair: wrongKey,
      );

      final recipientBundle = {
        'x25519_identity_key': base64Encode(bobX25519Public.bytes),
        'signed_pre_key': base64Encode(bobSPKPublic.bytes),
        'signed_pre_key_signature': base64Encode(wrongSig.bytes),
      };

      final aliceIdentity = await _generateIdentityKeyPair();
      final result = await x3dh.performX3DHAsSender(
        myEd25519IdentityKey: aliceIdentity.ed25519,
        myX25519IdentityKey: aliceIdentity.x25519,
        recipientBundle: recipientBundle,
      );
      expect(result.sharedSecret, isNotEmpty);
    });
  });

  group('X3DH - Error Handling', () {
    test('missing x25519_identity_key throws', () async {
      final aliceIdentity = await _generateIdentityKeyPair();
      expect(
        () => x3dh.performX3DHAsSender(
          myEd25519IdentityKey: aliceIdentity.ed25519,
          myX25519IdentityKey: aliceIdentity.x25519,
          recipientBundle: {'signed_pre_key': 'abc'},
        ),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('Double Ratchet - Consecutive Messages', () {
    test('encrypt multiple messages with unique nonces', () async {
      final sharedSecret = List<int>.generate(32, (i) => i);
      final bobKeyPair = await X25519().newKeyPair();
      final bobPublic = await bobKeyPair.extractPublicKey();

      final aliceState = await ratchet.initSession(
        sharedSecret: sharedSecret,
        theirRatchetPublicKeyBase64: base64Encode(bobPublic.bytes),
      );

      final nonces = <String>{};
      final ciphertexts = <String>{};
      for (int i = 0; i < 10; i++) {
        final msg = await ratchet.encrypt(
          state: aliceState, plaintext: 'Msg $i',
        );
        nonces.add(msg['nonce'] as String);
        ciphertexts.add(msg['ciphertext'] as String);
      }
      expect(nonces.length, equals(10));
      expect(ciphertexts.length, equals(10));
      expect(aliceState.sendCount, equals(10));
    });
  });

  group('Double Ratchet - Serialization', () {
    test('state serialization round-trip', () async {
      final sharedSecret = List<int>.generate(32, (i) => i);
      final bobKeyPair = await X25519().newKeyPair();
      final bobPublic = await bobKeyPair.extractPublicKey();

      final state = await ratchet.initSession(
        sharedSecret: sharedSecret,
        theirRatchetPublicKeyBase64: base64Encode(bobPublic.bytes),
      );

      await ratchet.encrypt(state: state, plaintext: 'Test');

      final json = state.toJson();
      expect(json['root_key'], isNotNull);
      expect(json['send_count'], equals(1));

      final restored = RatchetState.fromJson(json);
      expect(restored.rootKey, equals(state.rootKey));
      expect(restored.sendCount, equals(1));
      expect(restored.sendingChainKey, equals(state.sendingChainKey));
    });

    test('skipped keys are serialized', () {
      final state = RatchetState(
        rootKey: List<int>.generate(32, (i) => i),
        skippedMessageKeys: {'0-key123': [1, 2, 3]},
      );

      final json = state.toJson();
      final restored = RatchetState.fromJson(json);
      expect(restored.skippedMessageKeys['0-key123'], equals([1, 2, 3]));
    });
  });
}
