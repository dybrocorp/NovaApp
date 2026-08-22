// FASE 0.5 — PASO 3 — Validación Criptográfica Profunda
// Tests del protocolo X3DH (Extended Triple Diffie-Hellman).
//
//   X3DH-1: Con One-Time PreKey (OPK) -> mismo shared secret
//   X3DH-2: Sin OPK -> mismo shared secret
//   X3DH-3: Manipulación (identity key / signed prekey / signature / OPK)

import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:novaapp/core/services/x3dh_service.dart';

void main() {
  final x3dh = X3DHService();

  Future<({SimpleKeyPair ed25519, SimpleKeyPair x25519})> genIdentity() async {
    final seed = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final ed = await Ed25519().newKeyPairFromSeed(seed);
    final x = await X25519().newKeyPairFromSeed(seed);
    return (ed25519: ed, x25519: x);
  }

  // Construye el bundle de Bob (correcto y firmado). Devuelve el bundle y los
  // keypairs privados de Bob necesarios para el lado receptor.
  Future<
      ({
        Map<String, String> bundle,
        ({SimpleKeyPair ed25519, SimpleKeyPair x25519}) identity,
        SimpleKeyPair spk,
        SimpleKeyPair? opk,
      })> buildBobBundle({bool withOpk = true}) async {
    final identity = await genIdentity();
    final spk = await X25519().newKeyPair();
    final spkPub = await spk.extractPublicKey();
    final ikX25519Pub = await identity.x25519.extractPublicKey();
    final ikEd25519Pub = await identity.ed25519.extractPublicKey();

    final signature =
        await Ed25519().sign(spkPub.bytes, keyPair: identity.ed25519);

    final bundle = <String, String>{
      'x25519_identity_key': base64Encode(ikX25519Pub.bytes),
      'ed25519_identity_key': base64Encode(ikEd25519Pub.bytes),
      'signed_pre_key': base64Encode(spkPub.bytes),
      'signed_pre_key_signature': base64Encode(signature.bytes),
    };

    SimpleKeyPair? opk;
    if (withOpk) {
      opk = await X25519().newKeyPair();
      final opkPub = await opk.extractPublicKey();
      bundle['one_time_pre_key'] = base64Encode(opkPub.bytes);
    }

    return (bundle: bundle, identity: identity, spk: spk, opk: opk);
  }

  group('TEST X3DH-1 — Con OPK', () {
    test('Alice y Bob derivan el mismo shared secret (IK+SPK+OPK)', () async {
      final bob = await buildBobBundle(withOpk: true);
      final alice = await genIdentity();

      final aliceResult = await x3dh.performX3DHAsSender(
        myEd25519IdentityKey: alice.ed25519,
        myX25519IdentityKey: alice.x25519,
        recipientBundle: bob.bundle,
      );

      final aliceX25519Pub = await alice.x25519.extractPublicKey();
      final bobSecret = await x3dh.performX3DHAsReceiver(
        myEd25519IdentityKey: bob.identity.ed25519,
        myX25519IdentityKey: bob.identity.x25519,
        mySignedPreKey: bob.spk,
        myOneTimePreKey: bob.opk,
        ephemeralPublicKeyBase64: aliceResult.ephemeralPublicKey,
        senderX25519IdentityKeyBase64: base64Encode(aliceX25519Pub.bytes),
      );

      expect(aliceResult.sharedSecret, equals(bobSecret));
      expect(aliceResult.sharedSecret.length, equals(32));
      expect(aliceResult.oneTimePreKeyId, isNotNull);
    });
  });

  group('TEST X3DH-2 — Sin OPK', () {
    test('Alice y Bob derivan el mismo shared secret (IK+SPK)', () async {
      final bob = await buildBobBundle(withOpk: false);
      final alice = await genIdentity();

      final aliceResult = await x3dh.performX3DHAsSender(
        myEd25519IdentityKey: alice.ed25519,
        myX25519IdentityKey: alice.x25519,
        recipientBundle: bob.bundle,
      );

      final aliceX25519Pub = await alice.x25519.extractPublicKey();
      final bobSecret = await x3dh.performX3DHAsReceiver(
        myEd25519IdentityKey: bob.identity.ed25519,
        myX25519IdentityKey: bob.identity.x25519,
        mySignedPreKey: bob.spk,
        myOneTimePreKey: null,
        ephemeralPublicKeyBase64: aliceResult.ephemeralPublicKey,
        senderX25519IdentityKeyBase64: base64Encode(aliceX25519Pub.bytes),
      );

      expect(aliceResult.sharedSecret, equals(bobSecret));
      expect(aliceResult.oneTimePreKeyId, isNull);
    });
  });

  group('TEST X3DH-3 — Manipulación', () {
    test('Modificar la firma -> aborta (firma inválida)', () async {
      final bob = await buildBobBundle(withOpk: false);
      final tampered = Map<String, String>.from(bob.bundle);
      // Corrompe la firma.
      final sig = base64Decode(tampered['signed_pre_key_signature']!);
      sig[0] ^= 0xFF;
      tampered['signed_pre_key_signature'] = base64Encode(sig);

      final alice = await genIdentity();
      expect(
        () => x3dh.performX3DHAsSender(
          myEd25519IdentityKey: alice.ed25519,
          myX25519IdentityKey: alice.x25519,
          recipientBundle: tampered,
        ),
        throwsA(isA<X3DHVerificationException>()),
      );
    });

    test('Modificar el signed prekey -> aborta (firma no corresponde)',
        () async {
      final bob = await buildBobBundle(withOpk: false);
      final tampered = Map<String, String>.from(bob.bundle);
      // Reemplaza el signed prekey por otro (la firma ya no lo cubre).
      final otherSpk = await X25519().newKeyPair();
      final otherSpkPub = await otherSpk.extractPublicKey();
      tampered['signed_pre_key'] = base64Encode(otherSpkPub.bytes);

      final alice = await genIdentity();
      expect(
        () => x3dh.performX3DHAsSender(
          myEd25519IdentityKey: alice.ed25519,
          myX25519IdentityKey: alice.x25519,
          recipientBundle: tampered,
        ),
        throwsA(isA<X3DHVerificationException>()),
      );
    });

    test('Modificar la identity public key (ed25519) -> aborta', () async {
      final bob = await buildBobBundle(withOpk: false);
      final tampered = Map<String, String>.from(bob.bundle);
      // Sustituye la clave de identidad Ed25519 usada para verificar la firma.
      final wrongIdentity = await Ed25519().newKeyPair();
      final wrongPub = await wrongIdentity.extractPublicKey();
      tampered['ed25519_identity_key'] = base64Encode(wrongPub.bytes);

      final alice = await genIdentity();
      expect(
        () => x3dh.performX3DHAsSender(
          myEd25519IdentityKey: alice.ed25519,
          myX25519IdentityKey: alice.x25519,
          recipientBundle: tampered,
        ),
        throwsA(isA<X3DHVerificationException>()),
      );
    });

    test('Modificar la one-time prekey -> shared secret diferente', () async {
      // La OPK no está firmada en X3DH; manipularla no aborta, pero produce
      // un shared secret distinto entre emisor y receptor (integridad de la
      // sesión rota -> la conversación no arranca).
      final bob = await buildBobBundle(withOpk: true);
      final tampered = Map<String, String>.from(bob.bundle);
      final wrongOpk = await X25519().newKeyPair();
      final wrongOpkPub = await wrongOpk.extractPublicKey();
      tampered['one_time_pre_key'] = base64Encode(wrongOpkPub.bytes);

      final alice = await genIdentity();
      final aliceResult = await x3dh.performX3DHAsSender(
        myEd25519IdentityKey: alice.ed25519,
        myX25519IdentityKey: alice.x25519,
        recipientBundle: tampered,
      );

      // Bob usa su OPK REAL -> los shared secrets NO coincidirán.
      final aliceX25519Pub = await alice.x25519.extractPublicKey();
      final bobSecret = await x3dh.performX3DHAsReceiver(
        myEd25519IdentityKey: bob.identity.ed25519,
        myX25519IdentityKey: bob.identity.x25519,
        mySignedPreKey: bob.spk,
        myOneTimePreKey: bob.opk, // OPK original
        ephemeralPublicKeyBase64: aliceResult.ephemeralPublicKey,
        senderX25519IdentityKeyBase64: base64Encode(aliceX25519Pub.bytes),
      );

      expect(aliceResult.sharedSecret, isNot(equals(bobSecret)),
          reason:
              'Manipular la OPK debe producir shared secrets distintos');
    });
  });
}
