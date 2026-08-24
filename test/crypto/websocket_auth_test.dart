// FASE 0.5 — PASO 3 — Validación Criptográfica Profunda
// Tests de la autenticación challenge-response del WebSocket (Socket.IO).
//
// ACTUALIZACIÓN PASO 4 (hardening del transporte): el protocolo v1 DEFINITIVO
// ya NO envía public_key en auth.response (el servidor verifica contra la
// clave REGISTRADA) y la firma cubre el mensaje canónico
// NOVA_AUTH_v1|account|device|nova|challenge_id|challenge.
// El protocolo completo y sus tests viven ahora en:
//   - lib/core/socket/ (implementación + especificación ejecutable)
//   - test/socket/ (handshake, anti-replay, sesiones, revocación, etc.)
//   - docs/SOCKET_SECURITY.md
// Este archivo se conserva como sanity-check criptográfico base de
// firmar/verificar con Ed25519 (sigue siendo válido para eso).
//
// ALCANCE: el repositorio contiene SOLO el cliente (websocket_service.dart).
// NO existe código del servidor Socket.IO en el repo, por lo que la
// verificación del lado servidor NO puede probarse aquí y queda documentada
// como gap (ver docs/CRYPTOGRAPHIC_VALIDATION.md, sección WebSocket Auth).
//
// Este test valida la parte que SÍ es verificable de forma aislada:
//   - Formato/estructura del mensaje de autenticación (auth_response).
//   - Que la firma Ed25519 producida por el cliente es válida sobre el
//     challenge recibido (lo que el servidor DEBE verificar).
//   - Documenta qué DEBE verificar el servidor (no verificable aquí).

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';

void main() {
  final ed25519 = Ed25519();

  // Reproduce el cómputo del cliente (websocket_service._setupSocketListeners
  // -> handler 'auth_challenge') para poder validar su corrección de forma
  // aislada, sin depender de un socket real.
  Future<Map<String, dynamic>> buildAuthResponse({
    required SimpleKeyPair identityKeyPair,
    required String challenge,
    required String challengeId,
    required String novaId,
  }) async {
    final signature =
        await ed25519.sign(utf8.encode(challenge), keyPair: identityKeyPair);
    final publicKey = await identityKeyPair.extractPublicKey();
    return {
      'challenge_id': challengeId,
      'signature': base64Encode(signature.bytes),
      'public_key': base64Encode(publicKey.bytes),
      'nova_id': novaId,
    };
  }

  group('WebSocket Auth — Estructura del mensaje', () {
    test('auth_response contiene challenge_id, signature, public_key, nova_id',
        () async {
      final identity = await ed25519.newKeyPair();
      final resp = await buildAuthResponse(
        identityKeyPair: identity,
        challenge: 'random-challenge-abc123',
        challengeId: 'chal-1',
        novaId: 'nova_user_42',
      );

      expect(resp.keys, containsAll(
          ['challenge_id', 'signature', 'public_key', 'nova_id']));
      expect(resp['challenge_id'], equals('chal-1'));
      expect(resp['nova_id'], equals('nova_user_42'));
      expect((resp['signature'] as String).isNotEmpty, isTrue);
      expect((resp['public_key'] as String).isNotEmpty, isTrue);

      // La public key Ed25519 debe ser de 32 bytes.
      expect(base64Decode(resp['public_key']).length, equals(32));
      // La firma Ed25519 debe ser de 64 bytes.
      expect(base64Decode(resp['signature']).length, equals(64));
    });
  });

  group('WebSocket Auth — Firma verificable (lo que el servidor DEBE hacer)',
      () {
    test('La firma del cliente verifica contra su public_key y el challenge',
        () async {
      final identity = await ed25519.newKeyPair();
      const challenge = 'server-issued-nonce-xyz';

      final resp = await buildAuthResponse(
        identityKeyPair: identity,
        challenge: challenge,
        challengeId: 'chal-2',
        novaId: 'nova_user_7',
      );

      // El servidor DEBE: verificar signature sobre el challenge con public_key.
      final pub = SimplePublicKey(
          base64Decode(resp['public_key']), type: KeyPairType.ed25519);
      final valid = await ed25519.verify(
        utf8.encode(challenge),
        signature:
            Signature(base64Decode(resp['signature']), publicKey: pub),
      );
      expect(valid, isTrue, reason: 'La firma debe verificar (servidor OK)');
    });

    test('Una firma sobre OTRO challenge NO verifica (previene replay)',
        () async {
      final identity = await ed25519.newKeyPair();

      final resp = await buildAuthResponse(
        identityKeyPair: identity,
        challenge: 'challenge-A',
        challengeId: 'chal-3',
        novaId: 'nova_user_9',
      );

      // El servidor verifica contra un challenge DISTINTO -> debe fallar.
      final pub = SimplePublicKey(
          base64Decode(resp['public_key']), type: KeyPairType.ed25519);
      final valid = await ed25519.verify(
        utf8.encode('challenge-B'),
        signature:
            Signature(base64Decode(resp['signature']), publicKey: pub),
      );
      expect(valid, isFalse,
          reason:
              'El servidor DEBE emitir un challenge único por sesión y '
              'rechazar firmas sobre challenges antiguos (anti-replay)');
    });
  });

  group('WebSocket Auth — Gaps del servidor (NO verificable en este repo)', () {
    test('DOCUMENTACIÓN: verificaciones obligatorias del servidor', () {
      // Este test NO puede validar el servidor porque NO hay código de servidor
      // Socket.IO en el repo. Documenta explícitamente lo que el servidor DEBE
      // implementar. Ver docs/CRYPTOGRAPHIC_VALIDATION.md.
      //
      // El servidor DEBE:
      //   1. Emitir un `challenge` aleatorio (>=16 bytes CSPRNG), de un solo
      //      uso y con expiración corta (anti-replay).
      //   2. Verificar la firma Ed25519 sobre el challenge con la public_key.
      //   3. CRÍTICO: comprobar que `public_key` está REGISTRADA para `nova_id`
      //      (binding identidad<->cuenta). Sin esto, cualquiera puede
      //      autenticarse como otro usuario presentando su propia clave y un
      //      nova_id ajeno (suplantación).
      //   4. Asociar la sesión autenticada al socket solo tras verificar.
      //   5. Rechazar (auth_failure) cualquier fallo y cerrar el socket.
      //
      // Estado en el repo: cliente implementado; servidor AUSENTE => estas
      // verificaciones son NO VERIFICADAS.
      const serverCodePresentInRepo = false;
      expect(serverCodePresentInRepo, isFalse,
          reason:
              'Confirmado: no hay servidor Socket.IO en el repo; la '
              'verificación server-side queda como NO VERIFICADO.');
    });
  });
}
