// FASE 0.5 — PASO 4 — Hardening Socket.IO/WebSocket
// Protocol-level handshake tests: the client (AuthSigner) is exercised
// against the executable server specification (HandshakeEngine +
// ChallengeStore + DeviceRegistry + SessionRegistry).
//
// The repo contains ONLY the client; the server-side pieces here are the
// reference rules every production realtime server MUST implement
// (docs/SOCKET_SERVER_ARCHITECTURE.md). No real server is faked.
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/socket/auth/auth_payloads.dart';
import 'package:novaapp/core/socket/auth/auth_signer.dart';
import 'package:novaapp/core/socket/protocol/challenge_store.dart';
import 'package:novaapp/core/socket/protocol/device_registry.dart';
import 'package:novaapp/core/socket/protocol/handshake_engine.dart';
import 'package:novaapp/core/socket/protocol/session_registry.dart';

void main() {
  final ed25519 = Ed25519();

  // Deterministic world clock under the test's control.
  var now = DateTime.utc(2026, 1, 1, 12);
  DateTime clock() => now;
  void advance(Duration d) => now = now.add(d);

  late DeviceRegistry devices;
  late ChallengeStore challenges;
  late SessionRegistry sessions;
  late HandshakeEngine engine;

  late SimpleKeyPair identity;
  late List<int> registeredPublicKey;

  const accountId = 'acc-1';
  const deviceId = 'dev-1';
  const novaId = 'NOVA-ABCD12';

  setUp(() async {
    now = DateTime.utc(2026, 1, 1, 12);
    devices = DeviceRegistry();
    challenges = ChallengeStore(clock: clock, random: Random(1));
    sessions = SessionRegistry(clock: clock, random: Random(2));
    engine = HandshakeEngine(
      devices: devices,
      challenges: challenges,
      sessions: sessions,
    );

    identity = await ed25519.newKeyPair();
    registeredPublicKey = (await identity.extractPublicKey()).bytes;
    devices.register(
      accountId: accountId,
      deviceId: deviceId,
      novaId: novaId,
      ed25519PublicKey: registeredPublicKey,
    );
  });

  /// Full happy-path client flow for the given issued challenge.
  Future<Map<String, dynamic>?> clientRespond(
    IssuedChallengeData issued, {
    String? overrideDeviceId,
    String? overrideChallengeBase64,
    String? overrideSignature,
    SimpleKeyPair? withKeyPair,
  }) async {
    final wire = <String, dynamic>{
      'challenge_id': issued.challengeId,
      'challenge': overrideChallengeBase64 ?? issued.challengeBase64,
      'expires_at_ms': issued.expiresAtMs,
    };
    final challenge = AuthChallenge.tryParse(wire);
    if (challenge == null || !challenge.isValid) return null;
    final response = await const AuthSigner().buildResponse(
      challenge: challenge,
      identityKeyPair: withKeyPair ?? identity,
      accountId: accountId,
      deviceId: overrideDeviceId ?? deviceId,
      novaId: novaId,
      now: now,
    );
    if (response == null) return null;
    final map = response.toMap();
    if (overrideSignature != null) {
      map['signature'] = overrideSignature;
    }
    return map;
  }

  IssuedChallengeData serverIssue({String socketKey = 'sock-1'}) =>
      challenges.issue(
        socketKey: socketKey,
        accountId: accountId,
        deviceId: deviceId,
      );

  group('1. Conexión válida — flujo completo challenge/response', () {
    test('CONNECT -> CHALLENGE -> SIGN -> VERIFY -> SESSION', () async {
      final issued = serverIssue();
      final payload = await clientRespond(issued);
      expect(payload, isNotNull, reason: 'El cliente debe poder firmar');

      final result = await engine.handleAuthResponse(
        socketKey: 'sock-1',
        payload: payload!,
      );

      expect(result.outcome, HandshakeEngine.HandshakeOutcome.success);
      expect(result.session, isNotNull);
      expect(result.session!.accountId, accountId);
      expect(result.session!.deviceId, deviceId);
      expect(result.session!.novaId, novaId);
      expect(result.session!.sessionId.length, greaterThanOrEqualTo(32));

      // La sesión queda viva y validable para eventos.
      final validation = sessions.validate(
        result.session!.sessionId,
        socketKey: 'sock-1',
      );
      expect(validation, SessionValidation.ok);
    });

    test('La sesión NO requiere re-firmar en eventos posteriores', () async {
      final issued = serverIssue();
      final payload = await clientRespond(issued);
      final result = await engine.handleAuthResponse(
        socketKey: 'sock-1',
        payload: payload!,
      );
      // Eventos subsecuentes: solo session_id + socket, sin firma.
      expect(
        sessions.validate(result.session!.sessionId, socketKey: 'sock-1'),
        SessionValidation.ok,
      );
    });
  });

  group('2. Conexión inválida — payloads malformados', () {
    test('auth.response sin campos obligatorios es rechazado', () async {
      final issued = serverIssue();
      final result = await engine.handleAuthResponse(
        socketKey: 'sock-1',
        payload: <String, dynamic>{
          'challenge_id': issued.challengeId,
          // falta signature, account_id, device_id, nova_id
        },
      );
      expect(result.outcome, HandshakeEngine.HandshakeOutcome.badPayload);
      expect(
        HandshakeEngine.wireFailureCode(result.outcome),
        'AUTH_FAILED',
      );
    });

    test('challenge malformado es rechazado por el CLIENTE (fail closed)',
        () async {
      final bad = AuthChallenge.tryParse(<String, dynamic>{
        'challenge_id': 'x',
        'challenge': 'c2hvcnQ=', // < 32 bytes
        'expires_at_ms': now.millisecondsSinceEpoch + 60000,
      });
      expect(bad.isValid, isFalse,
          reason: 'Challenges < 32 bytes no son aceptados');

      final noExp = AuthChallenge.tryParse(<String, dynamic>{
        'challenge_id': 'x',
        'challenge': base64Of32Bytes(),
        // falta expires_at_ms
      });
      expect(noExp.isValid, isFalse);
    });
  });

  group('3. Challenge válido — aleatoriedad y single-attempt', () {
    test('Dos challenges consecutivos nunca son iguales', () {
      final a = serverIssue();
      final b = serverIssue();
      expect(a.challengeBase64, isNot(equals(b.challengeBase64)));
      expect(a.challengeId, isNot(equals(b.challengeId)));
    });

    test('El challenge tiene >= 32 bytes de entropía', () {
      final issued = serverIssue();
      expect(
        AuthChallenge.tryParse(issued.toWire()).isValid,
        isTrue,
      );
    });
  });

  group('4. Challenge expirado', () {
    test('Un challenge vencido es rechazado y quemado', () async {
      final issued = serverIssue();
      final payload = await clientRespond(issued);
      advance(const Duration(seconds: 61)); // ttl = 60s

      final result = await engine.handleAuthResponse(
        socketKey: 'sock-1',
        payload: payload!,
      );
      expect(result.outcome, HandshakeEngine.HandshakeOutcome.challengeRejected);
    });

    test('El CLIENTE rechaza localmente un challenge expirado', () async {
      final issued = serverIssue();
      advance(const Duration(seconds: 61));
      final payload = await clientRespond(issued);
      expect(payload, isNull,
          reason: 'buildResponse debe rehusarse a firmar challenges vencidos');
    });
  });

  group('5. Challenge reutilizado (replay)', () {
    test('El mismo challenge_id no autentica dos veces', () async {
      final issued = serverIssue();
      final payload = await clientRespond(issued);

      final first = await engine.handleAuthResponse(
        socketKey: 'sock-1',
        payload: payload!,
      );
      expect(first.outcome, HandshakeEngine.HandshakeOutcome.success);

      // Replay exacto del mismo payload (mismo challenge, misma firma):
      final replay = await engine.handleAuthResponse(
        socketKey: 'sock-1',
        payload: payload,
      );
      expect(
        replay.outcome,
        HandshakeEngine.HandshakeOutcome.challengeRejected,
        reason: 'Un challenge ya consumido DEBE ser rechazado',
      );
    });

    test('El challenge usado en OTRO socket también se rechaza', () async {
      final issued = serverIssue(socketKey: 'sock-1');
      final payload = await clientRespond(issued);
      final result = await engine.handleAuthResponse(
        socketKey: 'sock-2', // intento de robar el challenge ajeno
        payload: payload!,
      );
      expect(result.outcome, HandshakeEngine.HandshakeOutcome.challengeRejected);
    });
  });

  group('6. Firma inválida', () {
    test('Firma corrupta => badSignature (y challenge quemado)', () async {
      final issued = serverIssue();
      final payload = await clientRespond(issued);
      final sig = payload!['signature'] as String;

      // Corromper un byte del payload de la firma.
      final bytes = base64UrlDecodeLoose(sig);
      bytes[10] = bytes[10] ^ 0xFF;
      payload['signature'] = base64OfBytes(bytes);

      final result = await engine.handleAuthResponse(
        socketKey: 'sock-1',
        payload: payload,
      );
      expect(result.outcome, HandshakeEngine.HandshakeOutcome.badSignature);
      expect(HandshakeEngine.wireFailureCode(result.outcome), 'AUTH_FAILED');
    });
  });

  group('7. Device ID incorrecto', () {
    test('Device ID no registrado => rechazo genérico', () async {
      final issued = serverIssue();
      final payload = await clientRespond(issued, overrideDeviceId: 'dev-otro');
      final result = await engine.handleAuthResponse(
        socketKey: 'sock-1',
        payload: payload!,
      );
      expect(
        result.outcome,
        HandshakeEngine.HandshakeOutcome.deviceUnknownOrRevoked,
      );
    });

    test('Firma de OTRO dispositivo (clave distinta) no verifica', () async {
      final issued = serverIssue();
      final otherKey = await ed25519.newKeyPair();
      final payload = await clientRespond(issued, withKeyPair: otherKey);
      final result = await engine.handleAuthResponse(
        socketKey: 'sock-1',
        payload: payload!,
      );
      expect(result.outcome, HandshakeEngine.HandshakeOutcome.badSignature);
    });
  });

  group('13. Replay de firma sobre otro challenge', () {
    test('La firma del challenge A no sirve para el challenge B', () async {
      final issuedA = serverIssue();
      final payloadA = await clientRespond(issuedA);
      final sigA = payloadA!['signature'] as String;

      final issuedB = serverIssue();
      final result = await engine.handleAuthResponse(
        socketKey: 'sock-1',
        payload: <String, dynamic>{
          'challenge_id': issuedB.challengeId,
          'signature': sigA,
          'account_id': accountId,
          'device_id': deviceId,
          'nova_id': novaId,
          'ts_ms': now.millisecondsSinceEpoch,
        },
      );
      expect(result.outcome, HandshakeEngine.HandshakeOutcome.badSignature);
    });

    test('Challenge MODIFICADO (bytes alterados) falla la verificación',
        () async {
      final issued = serverIssue();
      // El atacante altera el challenge en tránsito; el cliente firma la
      // versión alterada; el servidor verifica contra el original.
      final tampered = base64OfBytes(
        base64UrlDecodeLoose(issued.challengeBase64)..[0] ^= 0x01,
      );
      final payload = await clientRespond(
        issued,
        overrideChallengeBase64: tampered,
      );
      final result = await engine.handleAuthResponse(
        socketKey: 'sock-1',
        payload: payload!,
      );
      expect(result.outcome, HandshakeEngine.HandshakeOutcome.badSignature);
    });
  });

  group('Errores genéricos (no enumeración)', () {
    test('Todos los fallos criptográficos responden AUTH_FAILED', () async {
      final issued = serverIssue();
      final bad = await clientRespond(issued, overrideDeviceId: 'nope');
      final r1 = await engine.handleAuthResponse(
        socketKey: 'sock-1',
        payload: bad!,
      );
      final r2 = await engine.handleAuthResponse(
        socketKey: 'sock-1',
        payload: <String, dynamic>{},
      );
      for (final result in [r1, r2]) {
        expect(
          HandshakeEngine.wireFailureCode(result.outcome),
          'AUTH_FAILED',
          reason: 'El código de error NO debe revelar qué check falló',
        );
      }
    });
  });
}

// ---- helpers ----

List<int> base64UrlDecodeLoose(String input) {
  final normalized = input.replaceAll('-', '+').replaceAll('_', '/');
  final padded = normalized + '=' * ((4 - normalized.length % 4) % 4);
  return base64.decode(padded);
}

String base64OfBytes(List<int> bytes) => base64.encode(bytes);

String base64Of32Bytes() => base64.encode(List<int>.generate(32, (i) => i));
