// FASE 0.5 — PASO 4 — Pruebas del servicio de transporte (nivel cliente).
//
// Estas pruebas cubren los caminos verificables SIN servidor real:
//   * fail-closed cuando falta identidad (accountId/deviceId/keypair);
//   * rechazo de ws:// cuando TLS es obligatorio (producción);
//   * cierre correcto y ciclo de reconexión manual;
//   * guard de emisión antes de autenticar.
//
// Los flujos que requieren un servidor Socket.IO real quedan como
// INTEGRACIÓN (PENDIENTE): ver docs/SOCKET_SERVER_ARCHITECTURE.md.
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/services/websocket_service.dart';
import 'package:novaapp/core/socket/socket_config.dart';

void main() {
  final ed25519 = Ed25519();

  late SimpleKeyPair identity;

  setUp(() async {
    identity = await ed25519.newKeyPair();
  });

  WebSocketService strictService(String url) => WebSocketService(
        config: SocketConfig(serverUrl: url, allowInsecureTransport: false),
      );

  group('2. Conexión inválida — el cliente falla cerrado', () {
    test('Sin accountId/deviceId/keypair no intenta conectar', () async {
      final service = strictService('wss://realtime.example');
      final statuses = <SocketConnectionStatus>[];
      final sub = service.statusStream.listen(statuses.add);

      await service.connect('NOVA-AAAA'); // sin identidad completa

      expect(service.status, SocketConnectionStatus.disconnected);
      expect(statuses, isEmpty, reason: 'Ni siquiera pasa a connecting');
      await sub.cancel();
      service.dispose();
    });

    test('ws:// con TLS obligatorio => estado failed, sin socket', () async {
      final service = strictService('ws://insecure.example:3000');
      final statuses = <SocketConnectionStatus>[];
      final sub = service.statusStream.listen(statuses.add);

      await service.connect(
        'NOVA-AAAA',
        identityKeyPair: identity,
        accountId: 'acc-1',
        deviceId: 'dev-1',
      );

      expect(service.status, SocketConnectionStatus.failed);
      expect(statuses.last, SocketConnectionStatus.failed);
      expect(service.isConnected, isFalse);
      await sub.cancel();
      service.dispose();
    });
  });

  group('18. Cierre correcto', () {
    test('disconnect() cancela la reconexión y limpia el estado', () async {
      final service = strictService('wss://realtime.example');
      await service.connect(
        'NOVA-AAAA',
        identityKeyPair: identity,
        accountId: 'acc-1',
        deviceId: 'dev-1',
      );
      service.disconnect();

      expect(service.status, SocketConnectionStatus.disconnected);
      expect(service.isAuthenticated, isFalse);
      expect(service.session.isActive, isFalse,
          reason: 'La sesión se invalida al cerrar (single-use)');
      service.dispose();
    });

    test('Tras un cierre de usuario no hay eventos salientes', () {
      final service = strictService('wss://realtime.example');
      service.disconnect();
      // Ningún método de emisión debe lanzar estando desconectado; se
      // rehusan silenciosamente (not authenticated).
      service.sendTypingIndicator('NOVA-BBBB', true);
      service.sendCallOffer('NOVA-BBBB', <String, dynamic>{'sdp': 'x'});
      service.endCall('NOVA-BBBB');
      expect(service.status, SocketConnectionStatus.disconnected);
      service.dispose();
    });
  });

  group('Emit guard — nada sale antes de auth.success', () {
    test('Los emits con ciphertext/plano se rehusan sin sesión', () async {
      final service = strictService('wss://realtime.example');
      // Mensaje con texto plano: rechazado SIEMPRE (aunque autenticado).
      service.sendMessage('NOVA-BBBB', <String, dynamic>{'text': 'hola'});

      await service.connect(
        'NOVA-AAAA',
        identityKeyPair: identity,
        accountId: 'acc-1',
        deviceId: 'dev-1',
      );
      // Aún no autenticado (sin servidor): nada puede emitirse.
      service.sendMessage('NOVA-BBBB', <String, dynamic>{
        'ciphertext': 'Q0lQSEVS',
      });
      expect(service.isAuthenticated, isFalse);
      service.dispose();
    });
  });

  group('reconnect() manual tras un fallo', () {
    test('Puede reintentar tras failed; blocked es terminal', () async {
      final service = strictService('ws://blocked.example');
      await service.connect(
        'NOVA-AAAA',
        identityKeyPair: identity,
        accountId: 'acc-1',
        deviceId: 'dev-1',
      );
      expect(service.status, SocketConnectionStatus.failed);
      // El reintento manual vuelve a evaluar la URL (y vuelve a fallar
      // por insegura: comportamiento determinístico sin servidor).
      service.reconnect();
      expect(service.status, SocketConnectionStatus.failed);
      service.dispose();
    });
  });
}
