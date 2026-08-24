// FASE 0.5 — PASO 4 — Sesiones: expiración, revocación, binding a device.
//
// §4 SESSION y §5 DEVICE REVOCATION del spec, verificadas contra la
// implementación de referencia del servidor (SessionRegistry).
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/socket/auth/auth_payloads.dart';
import 'package:novaapp/core/socket/auth/socket_session.dart';
import 'package:novaapp/core/socket/protocol/session_registry.dart';

void main() {
  var now = DateTime.utc(2026, 1, 1);
  DateTime clock() => now;

  late SessionRegistry registry;

  setUp(() {
    now = DateTime.utc(2026, 1, 1);
    registry = SessionRegistry(clock: clock, random: Random(3));
  });

  RegisteredSession create({String socket = 'sock-1', String device = 'dev-1'}) =>
      registry.create(
        socketKey: socket,
        accountId: 'acc-1',
        deviceId: device,
        novaId: 'NOVA-AAAA',
      );

  group('9. Sesión expirada', () {
    test('Una sesión vencida no valida para eventos', () {
      final session = create();
      expect(
        registry.validate(session.sessionId, socketKey: 'sock-1'),
        SessionValidation.ok,
      );

      now = now.add(const Duration(hours: 25)); // ttl = 24h
      expect(
        registry.validate(session.sessionId, socketKey: 'sock-1'),
        SessionValidation.expired,
      );
    });

    test('La sesión del CLIENTE también respeta la expiración', () {
      final clientSession = SocketSession.fromAuthSuccess(
        AuthSuccess(
          sessionId: 's1',
          accountId: 'acc-1',
          deviceId: 'dev-1',
          novaId: 'NOVA-AAAA',
          expiresAtMs: now.add(const Duration(hours: 24)).millisecondsSinceEpoch,
        ),
        expectedAccountId: 'acc-1',
        expectedDeviceId: 'dev-1',
        expectedNovaId: 'NOVA-AAAA',
      );
      expect(clientSession.isUsable(now: now), isTrue);
      now = now.add(const Duration(hours: 25));
      expect(clientSession.isUsable(now: now), isFalse);
    });
  });

  group('Binding de sesión', () {
    test('Una sesión no valida sobre otro socket (robo de session_id)', () {
      final session = create(socket: 'sock-1');
      expect(
        registry.validate(session.sessionId, socketKey: 'sock-2'),
        SessionValidation.invalid,
      );
    });

    test('auth.success con identidad ajena es rechazado por el CLIENTE', () {
      final mismatched = SocketSession.fromAuthSuccess(
        AuthSuccess(
          sessionId: 's2',
          accountId: 'acc-OTRA',
          deviceId: 'dev-1',
          novaId: 'NOVA-AAAA',
          expiresAtMs: now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
        ),
        expectedAccountId: 'acc-1',
        expectedDeviceId: 'dev-1',
        expectedNovaId: 'NOVA-AAAA',
      );
      expect(mismatched.isActive, isFalse,
          reason: 'Fail closed: identidad eco != identidad local');
    });

    test('Un nuevo socket del MISMO device crea sesión nueva y mata la vieja',
        () {
      final s1 = create(socket: 'sock-1', device: 'dev-1');
      final s2 = create(socket: 'sock-2', device: 'dev-1');
      expect(s1.sessionId, isNot(equals(s2.sessionId)));
      // La sesión vieja fue evictada: una sesión viva por dispositivo y NUNCA
      // se reusa tras una reconexión.
      expect(
        registry.validate(s1.sessionId, socketKey: 'sock-1'),
        SessionValidation.invalid,
      );
      expect(
        registry.validate(s2.sessionId, socketKey: 'sock-2'),
        SessionValidation.ok,
      );
    });
  });

  group('8. Revocación', () {
    test('revokeByDevice mata la sesión del dispositivo (no la de otros)',
        () {
      final s1 = create(socket: 'sock-1', device: 'dev-1');
      final s2 = create(socket: 'sock-2', device: 'dev-2');
      final killed = registry.revokeByDevice('dev-1');
      expect(killed, 1);
      expect(
        registry.validate(s1.sessionId, socketKey: 'sock-1'),
        SessionValidation.invalid,
      );
      expect(
        registry.validate(s2.sessionId, socketKey: 'sock-2'),
        SessionValidation.ok,
      );
    });

    test('revoke individual invalida una única sesión', () {
      final s1 = create(socket: 'sock-1', device: 'dev-1');
      final s2 = create(socket: 'sock-2', device: 'dev-2');
      registry.revoke(s1.sessionId);
      expect(
        registry.validate(s1.sessionId, socketKey: 'sock-1'),
        SessionValidation.invalid,
      );
      expect(
        registry.validate(s2.sessionId, socketKey: 'sock-2'),
        SessionValidation.ok,
      );
    });

    test('La renovación deslizante mantiene activas las sesiones en uso',
        () {
      final session = create();
      // 23h de actividad continua: nunca expira.
      now = now.add(const Duration(hours: 23));
      expect(
        registry.validate(session.sessionId, socketKey: 'sock-1'),
        SessionValidation.ok,
      );
      now = now.add(const Duration(hours: 23));
      expect(
        registry.validate(session.sessionId, socketKey: 'sock-1'),
        SessionValidation.ok,
      );
      // ...pero tras 24h SIN actividad muere.
      now = now.add(const Duration(hours: 24, minutes: 1));
      expect(
        registry.validate(session.sessionId, socketKey: 'sock-1'),
        SessionValidation.expired,
      );
    });
  });

  group('Sesión del cliente: single-use por conexión', () {
    test('SocketSession.none nunca es usable', () {
      expect(SocketSession.none.isUsable(now: now), isFalse);
      expect(SocketSession.none.isActive, isFalse);
    });
  });
}
