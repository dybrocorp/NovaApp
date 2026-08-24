// FASE 0.5 — PASO 4 — §15 HEARTBEAT: detección de conexiones muertas sin
// tráfico adicional (el ping/pong de engine.io ya existe).
import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/socket/heartbeat_watchdog.dart';

void main() {
  var now = DateTime.utc(2026, 1, 1);
  DateTime clock() => now;

  test('17. Con actividad reciente no se corta la conexión', () {
    final watchdog = HeartbeatWatchdog(
      silenceThreshold: const Duration(seconds: 75),
      clock: clock,
    );
    watchdog.noteActivity();
    now = now.add(const Duration(seconds: 60));
    expect(watchdog.evaluate(), HeartbeatAction.none);
    // Sigue vivo si sigue llegando tráfico.
    watchdog.noteActivity();
    now = now.add(const Duration(seconds: 60));
    expect(watchdog.evaluate(), HeartbeatAction.none);
  });

  test('Una conexión silenciosa > threshold se declara muerta', () {
    final watchdog = HeartbeatWatchdog(
      silenceThreshold: const Duration(seconds: 75),
      clock: clock,
    );
    watchdog.noteActivity();
    now = now.add(const Duration(seconds: 76));
    expect(watchdog.evaluate(), HeartbeatAction.disconnectDeadConnection);
  });

  test('Tras dispararse se rearma (no dispara en cadena)', () {
    final watchdog = HeartbeatWatchdog(
      silenceThreshold: const Duration(seconds: 75),
      clock: clock,
    );
    watchdog.noteActivity();
    now = now.add(const Duration(seconds: 90));
    expect(watchdog.evaluate(), HeartbeatAction.disconnectDeadConnection);
    // Sin nueva actividad registrada, no vuelve a disparar.
    now = now.add(const Duration(seconds: 90));
    expect(watchdog.evaluate(), HeartbeatAction.none);
  });

  test('reset() limpia el estado (después de un disconnect limpio)', () {
    final watchdog = HeartbeatWatchdog(
      silenceThreshold: const Duration(seconds: 75),
      clock: clock,
    );
    watchdog.noteActivity();
    watchdog.reset();
    now = now.add(const Duration(hours: 3));
    expect(watchdog.evaluate(), HeartbeatAction.none);
  });

  test('isDead puro: 75s exactos NO muere, >75s sí', () {
    final watchdog = HeartbeatWatchdog(
      silenceThreshold: const Duration(seconds: 75),
      clock: clock,
    );
    final last = DateTime.utc(2026, 1, 1);
    expect(
      watchdog.isDead(lastActivity: last, now: last.add(const Duration(seconds: 75))),
      isFalse,
    );
    expect(
      watchdog.isDead(lastActivity: last, now: last.add(const Duration(seconds: 76))),
      isTrue,
    );
  });
}
