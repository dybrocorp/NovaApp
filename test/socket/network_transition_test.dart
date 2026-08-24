// FASE 0.5 — PASO 4 — §7 NETWORK SWITCHING:
// WiFi -> datos móviles y datos móviles -> WiFi sin caer a offline.
import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/socket/network_transition_handler.dart';

void main() {
  late NetworkTransitionHandler handler;

  setUp(() {
    handler = NetworkTransitionHandler();
  });

  test('11. WiFi -> datos móviles con socket "conectado": reciclar conexión',
      () {
    // Estado inicial: online por wifi.
    handler.onConnectivityChanged(
      online: true,
      networkKind: 'wifi',
      socketConnected: true,
    );
    final decision = handler.onConnectivityChanged(
      online: true,
      networkKind: 'mobile',
      socketConnected: true,
    );
    expect(decision, ConnectivityDecision.forceDisconnectAndReconnect,
        reason: 'El socket viejo queda sospechoso tras el cambio de red');
    expect(handler.requiresResync, isFalse); // aún no marcado
    handler.markResyncNeeded();
    expect(handler.requiresResync, isTrue);
  });

  test('12. Datos móviles -> WiFi con socket caído: reconectar ya', () {
    handler.onConnectivityChanged(
      online: true,
      networkKind: 'mobile',
      socketConnected: false,
    );
    final decision = handler.onConnectivityChanged(
      online: true,
      networkKind: 'wifi',
      socketConnected: false,
    );
    expect(decision, ConnectivityDecision.reconnectNow);
  });

  test('Outage real (offline) y regreso: reconexión inmediata + resync', () {
    handler.onConnectivityChanged(
      online: true,
      networkKind: 'wifi',
      socketConnected: true,
    );
    // Se pierde Internet.
    expect(
      handler.onConnectivityChanged(
        online: false,
        networkKind: 'none',
        socketConnected: false,
      ),
      ConnectivityDecision.none,
    );
    // Vuelve (aún por la misma red): reconectar aunque el socket parezca vivo.
    expect(
      handler.onConnectivityChanged(
        online: true,
        networkKind: 'wifi',
        socketConnected: true,
      ),
      ConnectivityDecision.forceDisconnectAndReconnect,
    );
  });

  test('Sin cambios de red no se hace nada', () {
    handler.onConnectivityChanged(
      online: true,
      networkKind: 'wifi',
      socketConnected: true,
    );
    expect(
      handler.onConnectivityChanged(
        online: true,
        networkKind: 'wifi',
        socketConnected: true,
      ),
      ConnectivityDecision.none,
    );
  });

  test('El resync pendiente se limpia tras sync.response', () {
    handler.markResyncNeeded();
    expect(handler.requiresResync, isTrue);
    handler.resyncCompleted();
    expect(handler.requiresResync, isFalse);
  });
}
