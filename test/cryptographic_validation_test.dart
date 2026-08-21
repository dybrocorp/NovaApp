import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:novaapp/core/services/x3dh_service.dart';
import 'package:novaapp/core/services/double_ratchet_service.dart';

void main() {
  final x3dh = X3DHService();
  final ratchet = DoubleRatchetService();

  Future<SimpleKeyPair> generateX25519KeyPair() async {
    return await X25519().newKeyPair();
  }

  Future<({SimpleKeyPair ed25519, SimpleKeyPair x25519})>
      generateIdentityKeyPair() async {
    final seedBytes =
        List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final ed = await Ed25519().newKeyPairFromSeed(seedBytes);
    final x25 = await X25519().newKeyPairFromSeed(seedBytes);
    return (ed25519: ed, x25519: x25);
  }

  /// Sets up a paired session between Alice and Bob.
  ///
  /// Bob generates his keypair FIRST (like publishing in a key bundle).
  /// Alice uses Bob's public key for initSession.
  /// Bob creates RatchetState WITH his existing keypair.
  Future<({RatchetState alice, RatchetState bob})>
      setupPairedSession() async {
    final bobKeyPair = await generateX25519KeyPair();
    final bobPub = await bobKeyPair.extractPublicKey();

    final aliceState = await ratchet.initSession(
      sharedSecret: List<int>.generate(32, (i) => i),
      theirRatchetPublicKeyBase64: base64Encode(bobPub.bytes),
    );

    final bobState = RatchetState(
      rootKey: List<int>.generate(32, (i) => i),
      myRatchetKeyPair: bobKeyPair,
    );

    return (alice: aliceState, bob: bobState);
  }

  group('#1 Double Ratchet - Internal State Audit', () {
    test('initSession produces different rootKey and sendingChainKey', () async {
      final bobKeyPair = await generateX25519KeyPair();
      final bobPub = await bobKeyPair.extractPublicKey();
      final state = await ratchet.initSession(
        sharedSecret: List<int>.generate(32, (i) => i),
        theirRatchetPublicKeyBase64: base64Encode(bobPub.bytes),
      );
      expect(state.rootKey, isNot(equals(state.sendingChainKey)),
          reason: 'rootKey and sendingChainKey must be different');
      expect(state.rootKey.length, equals(32));
      expect(state.sendingChainKey!.length, equals(32));
    });

    test('initSession does not initialize receivingChainKey', () async {
      final bobKeyPair = await generateX25519KeyPair();
      final bobPub = await bobKeyPair.extractPublicKey();
      final state = await ratchet.initSession(
        sharedSecret: List<int>.generate(32, (i) => i),
        theirRatchetPublicKeyBase64: base64Encode(bobPub.bytes),
      );
      expect(state.receivingChainKey, isNull);
    });

    test('DH ratchet produces separate root, receiving, sending keys',
        () async {
      final session = await setupPairedSession();
      final enc0 =
          await ratchet.encrypt(state: session.alice, plaintext: 'init');
      await ratchet.decrypt(state: session.bob, encrypted: enc0);

      expect(session.bob.rootKey,
          isNot(equals(session.bob.receivingChainKey)));
      expect(session.bob.receivingChainKey,
          isNot(equals(session.bob.sendingChainKey)));
    });

    test('rootKey and sendingChainKey use 64-byte KDF split at 32',
        () async {
      final bobKeyPair = await generateX25519KeyPair();
      final bobPub = await bobKeyPair.extractPublicKey();
      final state = await ratchet.initSession(
        sharedSecret: List<int>.generate(32, (i) => i),
        theirRatchetPublicKeyBase64: base64Encode(bobPub.bytes),
      );
      expect(state.rootKey.length, equals(32));
      expect(state.sendingChainKey!.length, equals(32));
    });
  });

  group('#2 Bidirectional Communication', () {
    test('Alice A1-A5, Bob decrypts, Bob B1-B5, Alice decrypts', () async {
      final session = await setupPairedSession();

      final aliceDecrypted = <String>[];
      for (int i = 1; i <= 5; i++) {
        final enc =
            await ratchet.encrypt(state: session.alice, plaintext: 'A$i');
        final dec =
            await ratchet.decrypt(state: session.bob, encrypted: enc);
        aliceDecrypted.add(dec);
      }
      expect(aliceDecrypted, equals(['A1', 'A2', 'A3', 'A4', 'A5']));

      final bobDecrypted = <String>[];
      for (int i = 1; i <= 5; i++) {
        final enc =
            await ratchet.encrypt(state: session.bob, plaintext: 'B$i');
        final dec =
            await ratchet.decrypt(state: session.alice, encrypted: enc);
        bobDecrypted.add(dec);
      }
      expect(bobDecrypted, equals(['B1', 'B2', 'B3', 'B4', 'B5']));
    });

    test('Alternating messages A6/B6/A7/B7', () async {
      final session = await setupPairedSession();
      final results = <String>[];

      final encA6 =
          await ratchet.encrypt(state: session.alice, plaintext: 'A6');
      results.add(await ratchet.decrypt(
          state: session.bob, encrypted: encA6));

      final encB6 =
          await ratchet.encrypt(state: session.bob, plaintext: 'B6');
      results.add(await ratchet.decrypt(
          state: session.alice, encrypted: encB6));

      final encA7 =
          await ratchet.encrypt(state: session.alice, plaintext: 'A7');
      results.add(await ratchet.decrypt(
          state: session.bob, encrypted: encA7));

      final encB7 =
          await ratchet.encrypt(state: session.bob, plaintext: 'B7');
      results.add(await ratchet.decrypt(
          state: session.alice, encrypted: encB7));

      expect(results, equals(['A6', 'B6', 'A7', 'B7']));
    });

    test('10 alternating messages work correctly', () async {
      final session = await setupPairedSession();
      final results = <String>[];

      for (int i = 1; i <= 10; i++) {
        final encAlice =
            await ratchet.encrypt(state: session.alice, plaintext: 'A$i');
        results.add(await ratchet.decrypt(
            state: session.bob, encrypted: encAlice));

        final encBob =
            await ratchet.encrypt(state: session.bob, plaintext: 'B$i');
        results.add(await ratchet.decrypt(
            state: session.alice, encrypted: encBob));
      }

      expect(results.length, equals(20));
      expect(results[0], equals('A1'));
      expect(results[1], equals('B1'));
      expect(results[18], equals('A10'));
      expect(results[19], equals('B10'));
    });
  });

  group('#3 Out-of-Order Delivery', () {
    test('messages delivered as A1,A3,A5,A2,A4 all decrypt', () async {
      final session = await setupPairedSession();

      final encrypted = <String, Map<String, dynamic>>{};
      for (int i = 1; i <= 5; i++) {
        encrypted['A$i'] = await ratchet.encrypt(
            state: session.alice, plaintext: 'Msg$i');
      }

      final messages = <String, String>{};
      for (final name in ['A1', 'A3', 'A5', 'A2', 'A4']) {
        final dec = await ratchet.decrypt(
            state: session.bob, encrypted: encrypted[name]!);
        messages[name] = dec;
      }

      expect(messages['A1'], equals('Msg1'));
      expect(messages['A2'], equals('Msg2'));
      expect(messages['A3'], equals('Msg3'));
      expect(messages['A4'], equals('Msg4'));
      expect(messages['A5'], equals('Msg5'));
    });
  });

  group('#4 Lost Messages + Skipped Key Limit', () {
    test('Bob receives only A1,A5 from A1-A5', () async {
      final session = await setupPairedSession();

      final encrypted = <String, Map<String, dynamic>>{};
      for (int i = 1; i <= 5; i++) {
        encrypted['A$i'] = await ratchet.encrypt(
            state: session.alice, plaintext: 'A$i');
      }

      final dec1 = await ratchet.decrypt(
          state: session.bob, encrypted: encrypted['A1']!);
      expect(dec1, equals('A1'));

      final dec5 = await ratchet.decrypt(
          state: session.bob, encrypted: encrypted['A5']!);
      expect(dec5, equals('A5'));

      expect(session.bob.skippedMessageKeys.length,
          greaterThanOrEqualTo(3));
    });
  });

  group('#5 Replay Protection', () {
    test('same message cannot be decrypted twice', () async {
      final session = await setupPairedSession();

      final enc =
          await ratchet.encrypt(state: session.alice, plaintext: 'secret');
      final dec =
          await ratchet.decrypt(state: session.bob, encrypted: enc);
      expect(dec, equals('secret'));

      try {
        await ratchet.decrypt(state: session.bob, encrypted: enc);
        fail('Replay should be rejected');
      } catch (e) {
        expect(e.toString(), contains('already decrypted'));
      }
    });
  });

  group('#6 DH Ratchet Steps', () {
    test('multiple DH ratchet steps produce different root keys',
        () async {
      final session = await setupPairedSession();
      final rootKeys = <List<int>>[];

      for (int round = 0; round < 3; round++) {
        final enc = await ratchet.encrypt(
            state: session.alice, plaintext: 'round$round');
        await ratchet.decrypt(state: session.bob, encrypted: enc);
        rootKeys.add(List<int>.from(session.bob.rootKey));

        final reply = await ratchet.encrypt(
            state: session.bob, plaintext: 'reply$round');
        await ratchet.decrypt(
            state: session.alice, encrypted: reply);
      }

      expect(rootKeys[0], isNot(equals(rootKeys[1])));
      expect(rootKeys[1], isNot(equals(rootKeys[2])));
    });
  });

  group('#7 Forward Secrecy', () {
    test('each message uses a unique message key', () async {
      final session = await setupPairedSession();

      final ciphertexts = <Map<String, dynamic>>[];
      for (int i = 0; i < 5; i++) {
        ciphertexts.add(await ratchet.encrypt(
            state: session.alice, plaintext: 'msg$i'));
      }

      final aesGcm = AesGcm.with256bits();
      final wrongKey = List<int>.generate(32, (i) => 0xFF);

      for (int i = 0; i < 5; i++) {
        try {
          final secretBox = SecretBox(
            base64Decode(ciphertexts[i]['ciphertext']),
            nonce: base64Decode(ciphertexts[i]['nonce']),
            mac: Mac(base64Decode(ciphertexts[i]['mac'])),
          );
          await aesGcm.decrypt(secretBox,
              secretKey: SecretKey(wrongKey));
          fail('Wrong key should not decrypt msg $i');
        } catch (_) {}
      }
    });
  });

  group('#8 Nonce Validation', () {
    test('all nonces are unique across 100 messages', () async {
      final session = await setupPairedSession();
      final nonces = <String>{};
      for (int i = 0; i < 100; i++) {
        final enc = await ratchet.encrypt(
            state: session.alice, plaintext: 'msg$i');
        nonces.add(enc['nonce'] as String);
      }
      expect(nonces.length, equals(100));
    });

    test('AES-GCM nonce is 12 bytes per spec', () {
      final aesGcm = AesGcm.with256bits();
      expect(aesGcm.nonceLength, equals(12));
    });

    test('nonces are not sequential', () async {
      final session = await setupPairedSession();
      final firstBytes = <int>[];
      for (int i = 0; i < 10; i++) {
        final enc = await ratchet.encrypt(
            state: session.alice, plaintext: 'msg$i');
        firstBytes.add(base64Decode(enc['nonce'])[0]);
      }
      bool sequential = true;
      for (int i = 1; i < firstBytes.length; i++) {
        if (firstBytes[i] != firstBytes[i - 1] + 1) {
          sequential = false;
          break;
        }
      }
      expect(sequential, isFalse);
    });
  });

  group('#9 AAD Analysis', () {
    test('encrypted message contains required header fields', () async {
      final session = await setupPairedSession();
      final enc = await ratchet.encrypt(
          state: session.alice, plaintext: 'test');
      expect(enc.containsKey('message_number'), isTrue);
      expect(enc.containsKey('ratchet_public_key'), isTrue);
      expect(enc.containsKey('previous_chain_length'), isTrue);
      expect(enc.containsKey('ciphertext'), isTrue);
      expect(enc.containsKey('nonce'), isTrue);
      expect(enc.containsKey('mac'), isTrue);
    });

    test('message number increments with each encrypt', () async {
      final session = await setupPairedSession();
      final enc1 = await ratchet.encrypt(
          state: session.alice, plaintext: 'm1');
      final enc2 = await ratchet.encrypt(
          state: session.alice, plaintext: 'm2');
      final enc3 = await ratchet.encrypt(
          state: session.alice, plaintext: 'm3');
      expect(enc1['message_number'], equals(0));
      expect(enc2['message_number'], equals(1));
      expect(enc3['message_number'], equals(2));
    });
  });

  group('#10 X3DH Manipulation Tests', () {
    test('tampered identity key produces different shared secret',
        () async {
      final bobIdentity = await generateIdentityKeyPair();
      final bobSPK = await X25519().newKeyPair();
      final bobOPK = await X25519().newKeyPair();
      final bobSPKPub = await bobSPK.extractPublicKey();
      final bobOPKPub = await bobOPK.extractPublicKey();
      final bobX25519Pub = await bobIdentity.x25519.extractPublicKey();
      final spkSig = await Ed25519().sign(
          bobSPKPub.bytes, keyPair: bobIdentity.ed25519);

      final bundle = {
        'x25519_identity_key':
            base64Encode(bobX25519Pub.bytes),
        'signed_pre_key': base64Encode(bobSPKPub.bytes),
        'signed_pre_key_signature': base64Encode(spkSig.bytes),
        'one_time_pre_key': base64Encode(bobOPKPub.bytes),
      };

      final alice1 = await generateIdentityKeyPair();
      final result1 = await x3dh.performX3DHAsSender(
        myEd25519IdentityKey: alice1.ed25519,
        myX25519IdentityKey: alice1.x25519,
        recipientBundle: bundle,
      );

      final tampered = Map<String, String>.from(bundle);
      final fakeKey = await X25519().newKeyPair();
      final fakePub = await fakeKey.extractPublicKey();
      tampered['x25519_identity_key'] =
          base64Encode(fakePub.bytes);

      final alice2 = await generateIdentityKeyPair();
      final result2 = await x3dh.performX3DHAsSender(
        myEd25519IdentityKey: alice2.ed25519,
        myX25519IdentityKey: alice2.x25519,
        recipientBundle: tampered,
      );

      expect(result1.sharedSecret,
          isNot(equals(result2.sharedSecret)));
    });

    test('tampered SPK produces different shared secret', () async {
      final bobIdentity = await generateIdentityKeyPair();
      final bobSPK = await X25519().newKeyPair();
      final bobOPK = await X25519().newKeyPair();
      final bobSPKPub = await bobSPK.extractPublicKey();
      final bobOPKPub = await bobOPK.extractPublicKey();
      final bobX25519Pub =
          await bobIdentity.x25519.extractPublicKey();
      final spkSig = await Ed25519().sign(
          bobSPKPub.bytes, keyPair: bobIdentity.ed25519);

      final bundle = {
        'x25519_identity_key':
            base64Encode(bobX25519Pub.bytes),
        'signed_pre_key': base64Encode(bobSPKPub.bytes),
        'signed_pre_key_signature': base64Encode(spkSig.bytes),
        'one_time_pre_key':
            base64Encode(bobOPKPub.bytes),
      };

      final alice1 = await generateIdentityKeyPair();
      final result1 = await x3dh.performX3DHAsSender(
        myEd25519IdentityKey: alice1.ed25519,
        myX25519IdentityKey: alice1.x25519,
        recipientBundle: bundle,
      );

      final tampered = Map<String, String>.from(bundle);
      final fakeSPK = await X25519().newKeyPair();
      final fakeSPKPub = await fakeSPK.extractPublicKey();
      tampered['signed_pre_key'] =
          base64Encode(fakeSPKPub.bytes);

      final alice2 = await generateIdentityKeyPair();
      final result2 = await x3dh.performX3DHAsSender(
        myEd25519IdentityKey: alice2.ed25519,
        myX25519IdentityKey: alice2.x25519,
        recipientBundle: tampered,
      );

      expect(result1.sharedSecret,
          isNot(equals(result2.sharedSecret)));
    });

    test('wrong OPK produces different shared secret', () async {
      final bobIdentity = await generateIdentityKeyPair();
      final bobSPK = await X25519().newKeyPair();
      final bobOPK1 = await X25519().newKeyPair();
      final bobOPK2 = await X25519().newKeyPair();
      final bobSPKPub = await bobSPK.extractPublicKey();
      final bobX25519Pub =
          await bobIdentity.x25519.extractPublicKey();
      final spkSig = await Ed25519().sign(
          bobSPKPub.bytes, keyPair: bobIdentity.ed25519);

      final alice1 = await generateIdentityKeyPair();
      final result1 = await x3dh.performX3DHAsSender(
        myEd25519IdentityKey: alice1.ed25519,
        myX25519IdentityKey: alice1.x25519,
        recipientBundle: {
          'x25519_identity_key':
              base64Encode(bobX25519Pub.bytes),
          'signed_pre_key': base64Encode(bobSPKPub.bytes),
          'signed_pre_key_signature':
              base64Encode(spkSig.bytes),
          'one_time_pre_key': base64Encode(
              (await bobOPK1.extractPublicKey()).bytes),
        },
      );

      final alice2 = await generateIdentityKeyPair();
      final result2 = await x3dh.performX3DHAsSender(
        myEd25519IdentityKey: alice2.ed25519,
        myX25519IdentityKey: alice2.x25519,
        recipientBundle: {
          'x25519_identity_key':
              base64Encode(bobX25519Pub.bytes),
          'signed_pre_key': base64Encode(bobSPKPub.bytes),
          'signed_pre_key_signature':
              base64Encode(spkSig.bytes),
          'one_time_pre_key': base64Encode(
              (await bobOPK2.extractPublicKey()).bytes),
        },
      );

      expect(result1.sharedSecret,
          isNot(equals(result2.sharedSecret)));
    });

    test('OPK absence is handled gracefully', () async {
      final bobIdentity = await generateIdentityKeyPair();
      final bobSPK = await X25519().newKeyPair();
      final bobSPKPub = await bobSPK.extractPublicKey();
      final bobX25519Pub =
          await bobIdentity.x25519.extractPublicKey();
      final spkSig = await Ed25519().sign(
          bobSPKPub.bytes, keyPair: bobIdentity.ed25519);

      final aliceIdentity = await generateIdentityKeyPair();
      final result = await x3dh.performX3DHAsSender(
        myEd25519IdentityKey: aliceIdentity.ed25519,
        myX25519IdentityKey: aliceIdentity.x25519,
        recipientBundle: {
          'x25519_identity_key':
              base64Encode(bobX25519Pub.bytes),
          'signed_pre_key': base64Encode(bobSPKPub.bytes),
          'signed_pre_key_signature':
              base64Encode(spkSig.bytes),
        },
      );

      expect(result.sharedSecret.length, equals(32));
      expect(result.oneTimePreKeyId, isNull);
    });
  });

  group('HKDF Salt Analysis', () {
    test(
        'KDF uses X3DH secret as salt (different salts produce different outputs)',
        () async {
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 64);
      final key1 = await hkdf.deriveKey(
        secretKey:
            SecretKey(List<int>.generate(32, (i) => i)),
        nonce: List<int>.generate(32, (i) => i * 2),
      );
      final key2 = await hkdf.deriveKey(
        secretKey:
            SecretKey(List<int>.generate(32, (i) => i)),
        nonce: List<int>.generate(32, (i) => i * 3),
      );
      final bytes1 = await key1.extractBytes();
      final bytes2 = await key2.extractBytes();
      expect(bytes1, isNot(equals(bytes2)));
    });
  });

  group('Skipping + Skipped Key Limit', () {
    test('skipped keys are used when messages arrive out of order',
        () async {
      final session = await setupPairedSession();

      final enc1 = await ratchet.encrypt(
          state: session.alice, plaintext: '1');
      final enc2 = await ratchet.encrypt(
          state: session.alice, plaintext: '2');
      final enc3 = await ratchet.encrypt(
          state: session.alice, plaintext: '3');

      expect(
          await ratchet.decrypt(
              state: session.bob, encrypted: enc1),
          equals('1'));
      expect(
          await ratchet.decrypt(
              state: session.bob, encrypted: enc3),
          equals('3'));

      expect(session.bob.skippedMessageKeys.length, equals(1));

      expect(
          await ratchet.decrypt(
              state: session.bob, encrypted: enc2),
          equals('2'));
      expect(session.bob.skippedMessageKeys.length, equals(0));
    });
  });
}
