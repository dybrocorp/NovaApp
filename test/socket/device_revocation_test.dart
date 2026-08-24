// FASE 0.5 — PASO 4 — §5 DEVICE REVOCATION:
// un dispositivo revocado NO puede volver a autenticarse y sus sesiones
// mueren.
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
  var now = DateTime.utc(2026, 1, 1);
  DateTime clock() => now;

  late DeviceRegistry devices;
  late ChallengeStore challenges;
  late SessionRegistry sessions;
  late HandshakeEngine engine;
  late SimpleKeyPair identity;

  setUp(() async {
    now = DateTime.utc(2026, 1, 1);
    devices = DeviceRegistry();
    challenges = ChallengeStore(clock: clock, random: Random(1));
    sessions = SessionRegistry(clock: clock, random: Random(2));
    engine = HandshakeEngine(
      devices: devices,
      challenges: challenges,
      sessions: sessions,
    );
    identity = await ed25519.newKeyPair();
    devices.register(
      accountId: 'acc-1',
      deviceId: 'dev-1',
      novaId: 'NOVA-AAAA',
      ed25519PublicKey: (await identity.extractPublicKey()).bytes,
    );
  });

  Future<HandshakeResult> tryHandshake(String socketKey) async {
    final issued = challenges.issue(
      socketKey: socketKey,
      accountId: 'acc-1',
      deviceId: 'dev-1',
    );
    final challenge = AuthChallenge.tryParse(issued.toWire());
    final response = await const AuthSigner().buildResponse(
      challenge: challenge!,
      identityKeyPair: identity,
      accountId: 'acc-1',
      deviceId: 'dev-1',
      novaId: 'NOVA-AAAA',
      now: now,
    );
    return engine.handleAuthResponse(
      socketKey: socketKey,
      payload: response!.toMap(),
    );
  }

  test('8. Dispositivo revocado NO puede reconectarse', () async {
    // 1. Autenticación normal previa.
    final first = await tryHandshake('sock-1');
    expect(first.outcome, HandshakeEngine.HandshakeOutcome.success);

    // 2. El owner revoca el dispositivo (desde otro dispositivo).
    devices.revoke('dev-1');

    // 3. El servidor invalida todas sus sesiones...
    expect(sessions.revokeByDevice('dev-1'), 1);
    expect(
      sessions.validate(first.session!.sessionId, socketKey: 'sock-1'),
      SessionValidation.invalid,
    );

    // 4. ...y el dispositivo revocado NO puede volver a autenticarse.
    final retry = await tryHandshake('sock-2');
    expect(
      retry.outcome,
      HandshakeEngine.HandshakeOutcome.deviceUnknownOrRevoked,
      reason: 'Un dispositivo revocado jamás completa el handshake',
    );
    // 5. El error en el wire es genérico (no revela la causa).
    expect(HandshakeEngine.wireFailureCode(retry.outcome), 'AUTH_FAILED');
  });

  test('Un dispositivo revocado con firma VÁLIDA sigue rechazado', () async {
    devices.revoke('dev-1');
    final result = await tryHandshake('sock-1');
    // La firma es correcta: lo que falla es el STATUS del dispositivo.
    expect(
      result.outcome,
      HandshakeEngine.HandshakeOutcome.deviceUnknownOrRevoked,
    );
  });

  test('El estado del registry refleja la revocación', () {
    expect(devices.isActive('dev-1'), isTrue);
    devices.revoke('dev-1');
    expect(devices.isActive('dev-1'), isFalse);
    expect(devices.byDeviceId('dev-1')!.status, DeviceStatus.revoked);
  });
}
