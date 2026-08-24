// FASE 0.5 — PASO 4 — §17 LOGS y §18 ERRORES + §19 TRANSPORTE SEGURO:
// WSS obligatorio, redacción de logs, códigos genéricos.
import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/socket/auth/auth_payloads.dart';
import 'package:novaapp/core/socket/socket_config.dart';
import 'package:novaapp/core/socket/socket_events.dart';
import 'package:novaapp/core/socket/socket_log.dart';

void main() {
  group('19. Seguridad del transporte', () {
    test('wss:// es aceptado', () {
      final v = SocketConfig.validateServerUrl(
        'wss://realtime.novaapp.example',
        allowInsecure: false,
      );
      expect(v.ok, isTrue);
      expect(v.uri!.scheme, 'wss');
    });

    test('https:// es aceptado (socket.io sobre https)', () {
      expect(
        SocketConfig.validateServerUrl(
          'https://realtime.novaapp.example',
          allowInsecure: false,
        ).ok,
        isTrue,
      );
    });

    test('ws:// es RECHAZADO en producción (TLS obligatorio)', () {
      final v = SocketConfig.validateServerUrl(
        'ws://192.168.1.10:3000',
        allowInsecure: false,
      );
      expect(v.ok, isFalse);
      expect(v.error, SocketUrlError.insecureTransportRejected);
    });

    test('ws:// solo pasa con el flag explícito de desarrollo', () {
      expect(
        SocketConfig.validateServerUrl(
          'ws://10.0.2.2:3000',
          allowInsecure: true,
        ).ok,
        isTrue,
      );
    });

    test('Basura y esquemas raros son rechazados', () {
      expect(
        SocketConfig.validateServerUrl('no soy una url', allowInsecure: true)
            .error,
        SocketUrlError.invalidUrl,
      );
      expect(
        SocketConfig.validateServerUrl('ftp://x.example', allowInsecure: true)
            .error,
        SocketUrlError.invalidScheme,
      );
    });
  });

  group('17. Redacción de logs', () {
    test('scrub() redacta secretos en el primer y segundo nivel', () {
      final scrubbed = SocketLog.scrub(<String, dynamic>{
        'challenge': 'c3VwZXIgc2VjcmV0',
        'signature': 'c2ln',
        'session_id': 'sess-123',
        'nested': <String, dynamic>{
          'token': 'jwt-abc',
          'public': 'ok-to-show',
        },
      });
      expect(scrubbed['challenge'], '[REDACTED]');
      expect(scrubbed['signature'], '[REDACTED]');
      expect(scrubbed['session_id'], '[REDACTED]');
      final nested = scrubbed['nested']! as Map<String, dynamic>;
      expect(nested['token'], '[REDACTED]');
      expect(nested['public'], 'ok-to-show');
    });

    test('id() muestra solo un prefijo corto', () {
      expect(SocketLog.id('device-abcdef-123456'), 'devi…');
      expect(SocketLog.id(''), '—');
      expect(SocketLog.id(null), '—');
    });

    test('url() mantiene scheme+host pero suelta query/path', () {
      final out = SocketLog.url(
        'wss://realtime.novaapp.example/socket.io/?EIO=4&token=SECRET',
      );
      expect(out, 'wss://realtime.novaapp.example');
      expect(out.contains('SECRET'), isFalse);
    });

    test('Los eventos cliente-emisibles excluyen los de servidor', () {
      expect(isClientEmittableEvent('auth.response'), isTrue);
      expect(isClientEmittableEvent('message.send'), isTrue);
      expect(isClientEmittableEvent('auth.challenge'), isFalse);
      expect(isClientEmittableEvent('auth.success'), isFalse);
      expect(isClientEmittableEvent('device.revoked'), isFalse);
      expect(isClientEmittableEvent('message.new'), isFalse);
      expect(isClientEmittableEvent('call.offer'), isTrue);
      expect(domainForEvent('sync.request'), SocketEventDomain.sync);
      expect(domainForEvent('otro.cualquiera'), isNull);
    });
  });

  group('18. Códigos de error genéricos', () {
    test('parseAuthFailureCode mapea solo los códigos seguros', () {
      expect(parseAuthFailureCode(<String, dynamic>{'code': 'RATE_LIMITED'}),
          SocketAuthFailureCode.rateLimited);
      expect(parseAuthFailureCode(<String, dynamic>{'code': 'DEVICE_REVOKED'}),
          SocketAuthFailureCode.deviceRevoked);
      // Cualquier otro detalle del servidor cae en el genérico.
      expect(parseAuthFailureCode(<String, dynamic>{'code': 'signature incorrect for device X'}),
          SocketAuthFailureCode.authFailed);
      expect(parseAuthFailureCode(null), SocketAuthFailureCode.authFailed);
    });
  });
}
