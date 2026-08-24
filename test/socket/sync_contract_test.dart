// FASE 0.5 — Contrato de SYNC entre cliente Flutter y Realtime Server.
//
// Estas pruebas fijan el contrato de cable que la auditoría E2E detectó
// roto: el cliente enviaba `last_cursor` (un único escalar global)
// mientras el servidor lee `last_seq` por conversación. El resultado era
// que el servidor interpretaba SIEMPRE cursor = 0 y el cliente reenviaba
// eventos ya aplicados.
//
// Contrato correcto (server/src/realtime_server.ts, onSyncRequest):
//   * una conversación:  {conversation_id, last_seq}
//   * toda la cuenta:    {cursors: {<conversation_id>: <last_seq>}}
//   * respuesta:         {conversations: [{conversation_id, events, cursor}]}
//     con los campos de la única conversación replicados en la raíz.
//
// El cursor es `log_seq` (secuencia del LOG de eventos), distinta de
// `server_seq` (secuencia del MENSAJE): un acuse de recibo sobre un
// mensaje antiguo recibe un log_seq NUEVO, de modo que un cliente ya
// adelantado sigue recibiéndolo.
import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/socket/messaging/gap_detector.dart';

/// Réplica de la lógica de cursores del cliente, para poder verificar el
/// contrato sin levantar un socket real (eso lo cubre la suite Node).
class SyncCursorModel {
  final Map<String, int> cursors = <String, int>{};

  /// Payload de sync.request para una conversación concreta.
  Map<String, dynamic> requestFor(String conversationId) => <String, dynamic>{
        'conversation_id': conversationId,
        'last_seq': cursors[conversationId] ?? 0,
      };

  /// Payload de sync.request para toda la cuenta.
  Map<String, dynamic> requestAll() => <String, dynamic>{
        'cursors': Map<String, dynamic>.from(cursors),
      };

  /// Aplica una sync.response avanzando cursores sólo tras procesar.
  int apply(Map<String, dynamic> response) {
    var applied = 0;
    final conversations = response['conversations'];
    final entries = conversations is List
        ? conversations.cast<Map<String, dynamic>>()
        : <Map<String, dynamic>>[response];
    for (final entry in entries) {
      final conversationId = entry['conversation_id'];
      final events = entry['events'];
      if (events is List) applied += events.length;
      final cursor = entry['cursor'];
      if (conversationId is String && cursor is int) {
        final current = cursors[conversationId] ?? 0;
        if (cursor > current) cursors[conversationId] = cursor;
      }
    }
    return applied;
  }
}

void main() {
  group('Contrato de sync.request', () {
    test('Usa last_seq (no last_cursor) para una conversación', () {
      final model = SyncCursorModel();
      final payload = model.requestFor('conv-1');

      expect(payload.containsKey('last_seq'), isTrue,
          reason: 'el servidor lee last_seq');
      expect(payload.containsKey('last_cursor'), isFalse,
          reason: 'last_cursor era el nombre roto: el servidor lo ignora');
      expect(payload['conversation_id'], 'conv-1');
      expect(payload['last_seq'], 0);
    });

    test('Los cursores son POR conversación, no un escalar global', () {
      final model = SyncCursorModel();
      model.apply(<String, dynamic>{
        'conversations': <Map<String, dynamic>>[
          {'conversation_id': 'conv-a', 'events': <dynamic>[], 'cursor': 40},
          {'conversation_id': 'conv-b', 'events': <dynamic>[], 'cursor': 3},
        ],
      });

      expect(model.requestFor('conv-a')['last_seq'], 40);
      expect(model.requestFor('conv-b')['last_seq'], 3,
          reason: 'una conversación activa no debe arrastrar a otra');
      expect(model.requestFor('conv-nueva')['last_seq'], 0);
    });

    test('El sync de cuenta completa envía el mapa de cursores', () {
      final model = SyncCursorModel();
      model.cursors['conv-a'] = 7;
      model.cursors['conv-b'] = 2;

      final payload = model.requestAll();
      expect(payload['cursors'], <String, dynamic>{'conv-a': 7, 'conv-b': 2});
      expect(payload.containsKey('conversation_id'), isFalse,
          reason: 'sin conversation_id el servidor sincroniza toda la cuenta');
    });
  });

  group('Aplicación de sync.response', () {
    test('Acepta la forma multi-conversación', () {
      final model = SyncCursorModel();
      final applied = model.apply(<String, dynamic>{
        'conversations': <Map<String, dynamic>>[
          {
            'conversation_id': 'conv-a',
            'events': <Map<String, dynamic>>[
              {'type': 'message.new', 'log_seq': 1},
              {'type': 'message.new', 'log_seq': 2},
            ],
            'cursor': 2,
          },
        ],
      });

      expect(applied, 2);
      expect(model.cursors['conv-a'], 2);
    });

    test('Acepta la forma de una sola conversación (raíz)', () {
      final model = SyncCursorModel();
      final applied = model.apply(<String, dynamic>{
        'conversation_id': 'conv-a',
        'events': <Map<String, dynamic>>[
          {'type': 'message.new', 'log_seq': 5},
        ],
        'cursor': 5,
      });

      expect(applied, 1);
      expect(model.cursors['conv-a'], 5);
    });

    test('El cursor nunca retrocede ante una respuesta tardía', () {
      final model = SyncCursorModel();
      model.cursors['conv-a'] = 10;
      model.apply(<String, dynamic>{
        'conversation_id': 'conv-a',
        'events': <dynamic>[],
        'cursor': 4, // respuesta vieja que llega tarde
      });
      expect(model.cursors['conv-a'], 10);
    });
  });

  group('Sin duplicados entre entrega en vivo y sync', () {
    test('Un mensaje visto en vivo y luego replicado por sync se aplica una vez',
        () {
      final detector = SequenceGapDetector();

      // Llega en vivo.
      final live = detector.feed(
        conversationId: 'conv-a',
        messageId: 'msg-1',
        serverSeq: 1,
      );
      expect(live, SequenceGapDetector.FeedResult.accepted);

      // El mismo mensaje vuelve en una sync.response tras reconectar.
      final replayed = detector.feed(
        conversationId: 'conv-a',
        messageId: 'msg-1',
        serverSeq: 1,
      );
      expect(replayed, SequenceGapDetector.FeedResult.duplicate,
          reason: 'el mismo message_id nunca se procesa dos veces');
    });

    test('Un hueco en la secuencia se detecta y se recupera por sync', () {
      final detector = SequenceGapDetector();
      detector.feed(
          conversationId: 'conv-a', messageId: 'm1', serverSeq: 1);

      // Falta el 2: llega el 3.
      final gap = detector.feed(
          conversationId: 'conv-a', messageId: 'm3', serverSeq: 3);
      expect(gap, SequenceGapDetector.FeedResult.gapDetected);
      expect(detector.hasPendingGap('conv-a'), isTrue);
      expect(detector.lastContiguous('conv-a'), 1,
          reason: 'el cursor contiguo no salta por encima del hueco');

      // La sync entrega el que faltaba y el hueco se cierra.
      detector.feed(conversationId: 'conv-a', messageId: 'm2', serverSeq: 2);
      expect(detector.hasPendingGap('conv-a'), isFalse);
      expect(detector.lastContiguous('conv-a'), 3);
    });
  });
}
