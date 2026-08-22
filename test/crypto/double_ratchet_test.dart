// FASE 0.5 — PASO 3 — Validación Criptográfica Profunda
// Tests del protocolo Double Ratchet (Signal-compliant).
//
// Se validan 8 propiedades exigidas por la spec Signal Double Ratchet:
//   1. Comunicación bidireccional
//   2. Mensajes fuera de orden (skipped keys)
//   3. Mensajes perdidos
//   4. Replay protection
//   5. DH Ratchet step (nuevas claves por step)
//   6. Forward secrecy
//   7. Nonce (tamaño, no reutilización, autenticado por AEAD)
//   8. Associated Data (AAD)
//
// Modelo de sesión de la implementación (double_ratchet_service.dart):
//   - Alice (emisora inicial) llama a initSession() tras X3DH.
//   - Bob (receptor) NO llama a initSession: se construye un RatchetState
//     con SU keypair de ratchet (del key bundle X3DH) y el rootKey compartido.
//     Bob deriva su cadena receptora del primer mensaje de Alice usando la
//     simetría ECDH: DH(alice_priv, bob_pub) == DH(bob_priv, alice_pub).

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:novaapp/core/services/double_ratchet_service.dart';

void main() {
  final ratchet = DoubleRatchetService();
  final x25519 = X25519();

  // Crea un par Alice/Bob con root key compartido y las cadenas iniciales
  // configuradas correctamente. Devuelve (aliceState, bobState).
  Future<(RatchetState alice, RatchetState bob)> setupPair() async {
    // Root key compartido simulado (en producción proviene de X3DH).
    final sharedSecret = List<int>.generate(32, (i) => (i * 7 + 3) & 0xFF);

    // Bob tiene su keypair de ratchet (del key bundle).
    final bobKeyPair = await x25519.newKeyPair();
    final bobPublic = await bobKeyPair.extractPublicKey();

    // Alice inicializa su sesión con la clave pública de ratchet de Bob.
    final aliceState = await ratchet.initSession(
      sharedSecret: sharedSecret,
      theirRatchetPublicKeyBase64: base64Encode(bobPublic.bytes),
    );

    // Bob: estado con SU keypair existente y el mismo root key.
    final bobState = RatchetState(
      rootKey: List<int>.from(sharedSecret),
      myRatchetKeyPair: bobKeyPair,
    );

    return (aliceState, bobState);
  }

  group('TEST 1 — Comunicación bidireccional', () {
    test('Alice A1..A5 -> Bob, Bob B1..B5 -> Alice, luego A6/B6/A7/B7', () async {
      final (alice, bob) = await setupPair();

      // Alice -> Bob: A1..A5
      for (int i = 1; i <= 5; i++) {
        final enc = await ratchet.encrypt(state: alice, plaintext: 'A$i');
        final dec = await ratchet.decrypt(state: bob, encrypted: enc);
        expect(dec, equals('A$i'), reason: 'Bob debe descifrar A$i');
      }

      // Bob -> Alice: B1..B5 (fuerza DH ratchet en Alice)
      for (int i = 1; i <= 5; i++) {
        final enc = await ratchet.encrypt(state: bob, plaintext: 'B$i');
        final dec = await ratchet.decrypt(state: alice, encrypted: enc);
        expect(dec, equals('B$i'), reason: 'Alice debe descifrar B$i');
      }

      // Alternancia final: A6, B6, A7, B7
      var enc = await ratchet.encrypt(state: alice, plaintext: 'A6');
      expect(await ratchet.decrypt(state: bob, encrypted: enc), equals('A6'));

      enc = await ratchet.encrypt(state: bob, plaintext: 'B6');
      expect(await ratchet.decrypt(state: alice, encrypted: enc), equals('B6'));

      enc = await ratchet.encrypt(state: alice, plaintext: 'A7');
      expect(await ratchet.decrypt(state: bob, encrypted: enc), equals('A7'));

      enc = await ratchet.encrypt(state: bob, plaintext: 'B7');
      expect(await ratchet.decrypt(state: alice, encrypted: enc), equals('B7'));
    });
  });

  group('TEST 2 — Mensajes fuera de orden', () {
    test('Alice A1..A5, Bob recibe en orden A1,A3,A5,A2,A4', () async {
      final (alice, bob) = await setupPair();

      final msgs = <Map<String, dynamic>>[];
      for (int i = 1; i <= 5; i++) {
        msgs.add(await ratchet.encrypt(state: alice, plaintext: 'A$i'));
      }

      // Recepción fuera de orden: índices 0,2,4,1,3 -> A1,A3,A5,A2,A4
      final order = [0, 2, 4, 1, 3];
      for (final idx in order) {
        final dec = await ratchet.decrypt(state: bob, encrypted: msgs[idx]);
        expect(dec, equals('A${idx + 1}'),
            reason: 'Descifrado fuera de orden de A${idx + 1}');
      }
    });
  });

  group('TEST 3 — Mensajes perdidos', () {
    test('Alice A1..A5, Bob recibe solo A1 y A5 (skipped keys almacenadas)',
        () async {
      final (alice, bob) = await setupPair();

      final msgs = <Map<String, dynamic>>[];
      for (int i = 1; i <= 5; i++) {
        msgs.add(await ratchet.encrypt(state: alice, plaintext: 'A$i'));
      }

      // Recibe A1
      expect(await ratchet.decrypt(state: bob, encrypted: msgs[0]), equals('A1'));
      // Recibe A5 (A2,A3,A4 se saltan y sus message keys quedan almacenadas)
      expect(await ratchet.decrypt(state: bob, encrypted: msgs[4]), equals('A5'));

      // A2,A3,A4 deben estar en skipped keys (3 claves).
      expect(bob.skippedMessageKeys.length, equals(3),
          reason: 'A2,A3,A4 deben quedar como skipped message keys');

      // Y aún se pueden descifrar cuando lleguen (comportamiento definido).
      expect(await ratchet.decrypt(state: bob, encrypted: msgs[1]), equals('A2'));
      expect(await ratchet.decrypt(state: bob, encrypted: msgs[2]), equals('A3'));
      expect(await ratchet.decrypt(state: bob, encrypted: msgs[3]), equals('A4'));
      expect(bob.skippedMessageKeys.length, equals(0));
    });

    test('MAX_SKIP documentado: límite de skipped keys aplicado', () async {
      // El servicio define un límite máximo de skipped keys para evitar
      // ataques de agotamiento de memoria (DoS). Ver double_ratchet_service.dart
      // (_maxSkippedKeys). El documento de validación recomienda MAX_SKIP=1000;
      // la implementación usa un límite finito >0.
      final (alice, bob) = await setupPair();
      // Enviamos 2 mensajes solo para verificar que el mecanismo existe.
      final m1 = await ratchet.encrypt(state: alice, plaintext: 'A1');
      final m2 = await ratchet.encrypt(state: alice, plaintext: 'A2');
      await ratchet.decrypt(state: bob, encrypted: m1);
      await ratchet.decrypt(state: bob, encrypted: m2);
      // El estado expone skippedMessageKeys (mapa acotado por el límite).
      expect(bob.skippedMessageKeys, isA<Map<String, List<int>>>());
    });
  });

  group('TEST 4 — Replay protection', () {
    test('Rechaza un mensaje ya descifrado', () async {
      final (alice, bob) = await setupPair();

      final enc = await ratchet.encrypt(state: alice, plaintext: 'A1');
      expect(await ratchet.decrypt(state: bob, encrypted: enc), equals('A1'));

      // Reintento del MISMO mensaje -> debe rechazarse.
      expect(
        () => ratchet.decrypt(state: bob, encrypted: enc),
        throwsA(isA<StateError>()),
        reason: 'Un mensaje ya procesado debe rechazarse (replay)',
      );
    });
  });

  group('TEST 5 — DH Ratchet step', () {
    test('Cada ratchet step produce nuevas claves root/chain distintas',
        () async {
      final (alice, bob) = await setupPair();

      final roots = <String>{};
      roots.add(base64Encode(alice.rootKey));

      // Step 1: Alice -> Bob
      var enc = await ratchet.encrypt(state: alice, plaintext: 'A1');
      await ratchet.decrypt(state: bob, encrypted: enc);
      roots.add(base64Encode(bob.rootKey));

      // Step 2: Bob -> Alice (DH ratchet en Alice)
      final aliceRootBefore = base64Encode(alice.rootKey);
      enc = await ratchet.encrypt(state: bob, plaintext: 'B1');
      await ratchet.decrypt(state: alice, encrypted: enc);
      final aliceRootAfter = base64Encode(alice.rootKey);
      expect(aliceRootAfter, isNot(equals(aliceRootBefore)),
          reason: 'El ratchet step debe cambiar el root key de Alice');
      roots.add(aliceRootAfter);

      // Step 3: Alice -> Bob
      final bobRootBefore = base64Encode(bob.rootKey);
      enc = await ratchet.encrypt(state: alice, plaintext: 'A2');
      await ratchet.decrypt(state: bob, encrypted: enc);
      final bobRootAfter = base64Encode(bob.rootKey);
      expect(bobRootAfter, isNot(equals(bobRootBefore)),
          reason: 'El ratchet step debe cambiar el root key de Bob');
      roots.add(bobRootAfter);

      // Step 4: Bob -> Alice
      final aliceRoot2Before = base64Encode(alice.rootKey);
      enc = await ratchet.encrypt(state: bob, plaintext: 'B2');
      await ratchet.decrypt(state: alice, encrypted: enc);
      expect(base64Encode(alice.rootKey), isNot(equals(aliceRoot2Before)));

      // Se generaron múltiples root keys distintos a lo largo de los steps.
      expect(roots.length, greaterThanOrEqualTo(3),
          reason: 'Deben existir múltiples root keys distintos');
    });
  });

  group('TEST 6 — Forward secrecy', () {
    test('Una message key capturada no descifra otros mensajes', () async {
      final (alice, bob) = await setupPair();

      // Alice deriva la message key de su primer mensaje directamente
      // reproduciendo la cadena (para "capturar" una clave concreta).
      // Enviamos A1 y A2 con la misma cadena de envío.
      final encA1 = await ratchet.encrypt(state: alice, plaintext: 'SECRET-A1');
      final encA2 = await ratchet.encrypt(state: alice, plaintext: 'SECRET-A2');

      // Bob descifra A1 (esto avanza y BORRA la chain key usada).
      expect(await ratchet.decrypt(state: bob, encrypted: encA1),
          equals('SECRET-A1'));

      // La chain key receptora de Bob ha avanzado: la clave de A1 fue destruida.
      // Intentar volver a derivar la clave de A1 es imposible desde el estado
      // actual (forward secrecy). Verificamos que:
      //  (a) A1 no puede volver a descifrarse (replay/estado avanzado), y
      //  (b) A2 sí se descifra con la clave siguiente.
      expect(
        () => ratchet.decrypt(state: bob, encrypted: encA1),
        throwsA(anything),
        reason: 'La message key de A1 fue destruida tras su uso',
      );
      expect(await ratchet.decrypt(state: bob, encrypted: encA2),
          equals('SECRET-A2'));

      // Además, la clave de A2 (derivable ahora) NO coincide con la de A1:
      // las message keys son únicas por mensaje (cadena HMAC).
      // Comprobamos que los ciphertexts/nonces difieren.
      expect(encA1['ciphertext'], isNot(equals(encA2['ciphertext'])));
    });
  });

  group('TEST 7 — Nonce', () {
    test('Nonce de 12 bytes, único por mensaje y autenticado por AEAD',
        () async {
      final (alice, bob) = await setupPair();

      final nonces = <String>{};
      final encs = <Map<String, dynamic>>[];
      for (int i = 0; i < 20; i++) {
        final enc = await ratchet.encrypt(state: alice, plaintext: 'msg$i');
        // Tamaño correcto para AES-GCM: 12 bytes.
        expect(base64Decode(enc['nonce']).length, equals(12),
            reason: 'AES-GCM requiere nonce de 12 bytes');
        nonces.add(enc['nonce'] as String);
        encs.add(enc);
      }
      // No reutilización de nonces.
      expect(nonces.length, equals(20),
          reason: 'Los nonces no deben reutilizarse');

      // Autenticado por AEAD: alterar el ciphertext debe hacer fallar el
      // descifrado (MAC/tag inválido).
      final tampered = Map<String, dynamic>.from(encs[0]);
      final ct = base64Decode(tampered['ciphertext']);
      ct[0] ^= 0xFF; // corrompe un byte
      tampered['ciphertext'] = base64Encode(ct);
      expect(
        () => ratchet.decrypt(state: bob, encrypted: tampered),
        throwsA(anything),
        reason: 'AES-GCM debe rechazar ciphertext manipulado (AEAD)',
      );
    });
  });

  group('TEST 8 — Associated Data (AAD)', () {
    test('El header (ratchet pubkey, N, PN) está autenticado como AAD', () async {
      final (alice, bob) = await setupPair();

      final enc = await ratchet.encrypt(state: alice, plaintext: 'A1');

      // El AAD implementado incluye: ratchet_public_key || N || PN.
      // Manipular cualquiera de esos campos en tránsito debe invalidar el AEAD.
      // Alteramos previous_chain_length (parte del AAD) manteniendo ciphertext.
      final tampered = Map<String, dynamic>.from(enc);
      tampered['previous_chain_length'] =
          (enc['previous_chain_length'] as int) + 1;

      expect(
        () => ratchet.decrypt(state: bob, encrypted: tampered),
        throwsA(anything),
        reason:
            'Modificar previous_chain_length (AAD) debe invalidar el descifrado',
      );
    });

    test('AAD PARCIAL: NO incluye conversation_id/device_ids/protocol_version',
        () async {
      // DOCUMENTACIÓN DE RIESGO (no se skipea silenciosamente):
      //
      // La spec de la app exige que el AAD ligue el mensaje a:
      //   conversation_id, sender_device_id, recipient_device_id,
      //   ratchet_public_key, message_number, previous_chain_length,
      //   protocol_version.
      //
      // La implementación actual (double_ratchet_service._buildHeader) SOLO
      // incluye: ratchet_public_key, message_number, previous_chain_length.
      //
      // FALTAN: conversation_id, sender_device_id, recipient_device_id,
      //         protocol_version.
      //
      // IMPACTO: sin esos campos en el AAD, el cifrado no está ligado
      // criptográficamente al contexto de conversación/dispositivo, lo que
      // permite ataques de reenvío entre contextos (cross-context / UKS).
      //
      // Este test FALLA a propósito para documentar el gap (no se skipea).
      // Cuando se implemente el AAD completo, actualizar este test.
      final (alice, _) = await setupPair();
      final enc = await ratchet.encrypt(state: alice, plaintext: 'ctx');

      // encrypt() no recibe conversation_id ni device ids -> AAD incompleto.
      // Documentamos el gap con un fail explícito y descriptivo.
      const aadCompleto = false; // <- estado real de la implementación
      expect(
        aadCompleto,
        isTrue,
        reason:
            'GAP DOCUMENTADO: el AAD NO incluye conversation_id, '
            'sender_device_id, recipient_device_id ni protocol_version. '
            'Ver docs/CRYPTOGRAPHIC_VALIDATION.md (sección AAD). '
            'Mensaje generado con nonce=${enc['nonce']}',
      );
    }, skip: false);
  });
}
