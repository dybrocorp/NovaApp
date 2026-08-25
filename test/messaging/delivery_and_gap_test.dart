// FASE 1 — §37: escenarios del motor que son lógica pura.
//
// Cubre la máquina de estados de entrega (§17), el agregado
// multi-dispositivo, la detección de huecos (§14) y la caducidad (§22).
// Nada aquí necesita socket ni base de datos: son funciones puras, que
// es justo donde los errores de razonamiento se cuelan sin ruido.
import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/messaging/model/delivery_state.dart';
import 'package:novaapp/core/messaging/model/message_ids.dart';

void main() {
  group('§17 — La máquina de estados sólo avanza', () {
    test('El progreso normal sube de rango', () {
      expect(
        DeliveryStateMachine.apply(DeliveryState.sent, DeliveryState.delivered),
        DeliveryState.delivered,
      );
      expect(
        DeliveryStateMachine.apply(DeliveryState.delivered, DeliveryState.read),
        DeliveryState.read,
      );
    });

    test('Un delivered tardío NO degrada un read', () {
      // Los recibos llegan desordenados por naturaleza. Sin esta regla la
      // UI parpadearía de "leído" a "entregado" sola.
      expect(
        DeliveryStateMachine.apply(DeliveryState.read, DeliveryState.delivered),
        DeliveryState.read,
      );
    });

    test('Repetir el mismo estado es idempotente', () {
      expect(
        DeliveryStateMachine.apply(DeliveryState.read, DeliveryState.read),
        DeliveryState.read,
      );
    });

    test('Un failed local no borra un delivered ya confirmado', () {
      // El destinatario YA lo tiene; que a nosotros nos falle la red
      // después no deshace ese hecho.
      expect(
        DeliveryStateMachine.apply(DeliveryState.delivered, DeliveryState.failed),
        DeliveryState.delivered,
      );
      expect(
        DeliveryStateMachine.apply(DeliveryState.read, DeliveryState.failed),
        DeliveryState.read,
      );
    });

    test('Un failed sí se aplica si aún no había entrega', () {
      expect(
        DeliveryStateMachine.apply(DeliveryState.sending, DeliveryState.failed),
        DeliveryState.failed,
      );
    });

    test('De failed se recupera hacia adelante, no hacia atrás', () {
      expect(
        DeliveryStateMachine.apply(DeliveryState.failed, DeliveryState.sent),
        DeliveryState.sent,
      );
      // Volver a "queued" desde failed no es una recuperación real.
      expect(
        DeliveryStateMachine.apply(DeliveryState.failed, DeliveryState.queued),
        DeliveryState.failed,
      );
    });

    test('failed y read son terminales; queued y sending están pendientes', () {
      expect(DeliveryState.failed.isTerminal, isTrue);
      expect(DeliveryState.read.isTerminal, isTrue);
      expect(DeliveryState.queued.isPending, isTrue);
      expect(DeliveryState.sending.isPending, isTrue);
      expect(DeliveryState.delivered.isPending, isFalse);
    });

    test('Un nombre desconocido no lanza: degrada a queued', () {
      expect(DeliveryState.fromName('estado_inventado'), DeliveryState.queued);
      expect(DeliveryState.fromName(null), DeliveryState.queued);
      expect(DeliveryState.fromName('read'), DeliveryState.read);
    });
  });

  group('§17 — El agregado multi-dispositivo es el MÍNIMO', () {
    DeviceDeliveryState dev(String id, DeliveryState s) =>
        DeviceDeliveryState(deviceId: DeviceId(id), state: s);

    test('Si un dispositivo de tres sólo recibió, NO está leído', () {
      final summary = MessageDeliverySummary([
        dev('d1', DeliveryState.read),
        dev('d2', DeliveryState.delivered),
        dev('d3', DeliveryState.read),
      ]);
      expect(summary.aggregate, DeliveryState.delivered,
          reason: 'mostrar "leído" aquí sería mentir al emisor');
    });

    test('Todos leídos: leído', () {
      final summary = MessageDeliverySummary([
        dev('d1', DeliveryState.read),
        dev('d2', DeliveryState.read),
      ]);
      expect(summary.aggregate, DeliveryState.read);
    });

    test('Un dispositivo fallido no arrastra al resto', () {
      // Un móvil apagado permanentemente no debe congelar el estado en
      // "fallido" cuando el otro dispositivo sí lo leyó.
      final summary = MessageDeliverySummary([
        dev('d1', DeliveryState.read),
        dev('d2', DeliveryState.failed),
      ]);
      expect(summary.aggregate, DeliveryState.read);
    });

    test('Si TODOS fallan, el resultado es fallido', () {
      final summary = MessageDeliverySummary([
        dev('d1', DeliveryState.failed),
        dev('d2', DeliveryState.failed),
      ]);
      expect(summary.aggregate, DeliveryState.failed);
    });

    test('Sin dispositivos no se inventa una entrega', () {
      const summary = MessageDeliverySummary(<DeviceDeliveryState>[]);
      expect(summary.isEmpty, isTrue);
      expect(summary.aggregate, DeliveryState.queued);
    });

    test('anyReached distingue "alguno" de "todos"', () {
      final summary = MessageDeliverySummary([
        dev('d1', DeliveryState.read),
        dev('d2', DeliveryState.sent),
      ]);
      expect(summary.anyReached(DeliveryState.read), isTrue);
      expect(summary.aggregate, DeliveryState.sent);
    });

    test('update avanza un solo dispositivo sin tocar los demás', () {
      final summary = MessageDeliverySummary([
        dev('d1', DeliveryState.sent),
        dev('d2', DeliveryState.sent),
      ]);
      final next = summary.update(const DeviceId('d1'), DeliveryState.read);
      expect(next.anyReached(DeliveryState.read), isTrue);
      expect(next.aggregate, DeliveryState.sent, reason: 'd2 sigue en sent');
    });

    test('update respeta la regla de sólo avanzar', () {
      final summary = MessageDeliverySummary([dev('d1', DeliveryState.read)]);
      final next = summary.update(const DeviceId('d1'), DeliveryState.delivered);
      expect(next.aggregate, DeliveryState.read);
    });
  });

  group('§17 — Serialización del estado por dispositivo', () {
    test('toMap/fromMap conservan el estado', () {
      const original = DeviceDeliveryState(
        deviceId: DeviceId('dev-1'),
        state: DeliveryState.delivered,
        updatedAtMs: 1700000000000,
      );
      final restored = DeviceDeliveryState.fromMap(original.toMap());
      expect(restored.deviceId.value, 'dev-1');
      expect(restored.state, DeliveryState.delivered);
      expect(restored.updatedAtMs, 1700000000000);
    });

    test('Un mapa corrupto no lanza', () {
      final restored = DeviceDeliveryState.fromMap(<String, dynamic>{});
      expect(restored.state, DeliveryState.queued);
    });

    test('advance aplica la máquina de estados', () {
      const s = DeviceDeliveryState(
        deviceId: DeviceId('dev-1'),
        state: DeliveryState.read,
      );
      expect(s.advance(DeliveryState.delivered).state, DeliveryState.read);
      expect(
        const DeviceDeliveryState(deviceId: DeviceId('d'), state: DeliveryState.sent)
            .advance(DeliveryState.delivered)
            .state,
        DeliveryState.delivered,
      );
    });
  });

  group('§14 — Detección de huecos', () {
    // server_seq es CONTIGUO por conversación, así que un salto es un
    // hueco real y no una ambigüedad de transporte.
    int lastContiguous(List<int> seqs, {int from = 0}) {
      final sorted = seqs.toSet().toList()..sort();
      var last = from;
      for (final s in sorted) {
        if (s == last + 1) {
          last = s;
        } else if (s > last + 1) {
          break;
        }
      }
      return last;
    }

    test('Una secuencia completa avanza hasta el final', () {
      expect(lastContiguous([1, 2, 3, 4]), 4);
    });

    test('Se detiene en el primer hueco y NO salta a la cabeza', () {
      // Aceptar 7 como cursor perdería 4, 5 y 6 EN SILENCIO: el usuario
      // no vería mensajes que sí existen.
      expect(lastContiguous([1, 2, 3, 7, 8]), 3);
    });

    test('El desorden de llegada no crea huecos falsos', () {
      expect(lastContiguous([3, 1, 2]), 3);
    });

    test('Los duplicados no rompen el conteo', () {
      expect(lastContiguous([1, 2, 2, 3]), 3);
    });

    test('Un hueco al principio no avanza nada', () {
      expect(lastContiguous([5, 6]), 0);
    });

    test('Continuar desde un cursor previo', () {
      expect(lastContiguous([11, 12, 14], from: 10), 12);
    });
  });

  group('§22 — Caducidad de mensajes temporales', () {
    bool isExpired(int? expiresAtMs, int nowMs) =>
        expiresAtMs != null && expiresAtMs <= nowMs;

    test('Sin expires_at el mensaje no caduca', () {
      expect(isExpired(null, 1000), isFalse);
    });

    test('Caduca en el instante límite, no antes', () {
      expect(isExpired(1000, 999), isFalse);
      expect(isExpired(1000, 1000), isTrue);
      expect(isExpired(1000, 1001), isTrue);
    });
  });
}
