// FASE 0.5 — PASO 4 — §10/§11/§12/§13 MENSAJES:
// solo ciphertext, ACK != DELIVERED != READ, idempotencia por message_id,
// deduplicación, orden por server_seq.
import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/socket/messaging/ack_state.dart';
import 'package:novaapp/core/socket/messaging/gap_detector.dart';
import 'package:novaapp/core/socket/messaging/message_envelope.dart';
import 'package:novaapp/core/socket/messaging/outbox.dart';
import 'package:novaapp/core/socket/protocol/message_dedup.dart';

MessageEnvelope envelope(String id, {String conversation = 'conv-1'}) =>
    MessageEnvelope(
      messageId: id,
      conversationId: conversation,
      senderDeviceId: 'dev-1',
      ciphertextBase64: 'Q0lQSEVSVEVYVA==',
      ciphertextHeaderType: 'dr.v1',
      clientTimestampMs: 1767225600000,
    );

void main() {
  var now = DateTime.utc(2026, 1, 1);
  DateTime clock() => now;

  group('11. Estados de entrega separados (SENT/DELIVERED/READ)', () {
    test('message.ack significa SÓLO recepción del servidor', () {
      var status = MessageDeliveryStatus.queued;
      status = AckStateMachine.apply(status, MessageDeliveryStatus.sent);
      expect(status, MessageDeliveryStatus.sent,
          reason: 'ACK = recibido por el servidor, no "delivered"');
    });

    test('sent -> delivered -> read avanza hacia adelante', () {
      var status = MessageDeliveryStatus.queued;
      status = AckStateMachine.apply(status, MessageDeliveryStatus.sent);
      status = AckStateMachine.apply(status, MessageDeliveryStatus.delivered);
      status = AckStateMachine.apply(status, MessageDeliveryStatus.read);
      expect(status, MessageDeliveryStatus.read);
    });

    test('Los estados nunca retroceden', () {
      var status = MessageDeliveryStatus.read;
      status = AckStateMachine.apply(status, MessageDeliveryStatus.delivered);
      expect(status, MessageDeliveryStatus.read);
      status = AckStateMachine.apply(status, MessageDeliveryStatus.sent);
      expect(status, MessageDeliveryStatus.read);
      status = AckStateMachine.apply(status, MessageDeliveryStatus.queued);
      expect(status, MessageDeliveryStatus.read);
    });

    test('failed no sobreescribe delivered/read', () {
      var status = MessageDeliveryStatus.delivered;
      status = AckStateMachine.apply(status, MessageDeliveryStatus.failed);
      expect(status, MessageDeliveryStatus.delivered);
      status = MessageDeliveryStatus.queued;
      status = AckStateMachine.apply(status, MessageDeliveryStatus.failed);
      expect(status, MessageDeliveryStatus.failed);
    });
  });

  group('12. Idempotencia — message_id estable', () {
    test('El outbox reenvía con el MISMO message_id tras reconexión', () {
      final outbox = OutboxQueue(clock: clock);
      final e = envelope('msg-fixed-id');
      outbox.enqueue(e);

      // Primer intento (se "envía" pero el server nunca responde).
      final first = outbox.dueEntries();
      expect(first.map((x) => x.envelope.messageId), ['msg-fixed-id']);
      outbox.markAttempted('msg-fixed-id', now);

      // Reconexión: reintento con el mismo id (el server deduplica).
      now = now.add(const Duration(seconds: 5));
      final retry = outbox.dueEntries();
      expect(retry.map((x) => x.envelope.messageId), ['msg-fixed-id']);
      expect(retry.first.envelope.ciphertextBase64, e.ciphertextBase64);
    });

    test('Tras message.ack el mensaje sale de la cola de pendientes', () {
      final outbox = OutboxQueue(clock: clock);
      outbox.enqueue(envelope('msg-1'));
      outbox.markAcked('msg-1');
      expect(outbox.byMessageId('msg-1')!.status, MessageDeliveryStatus.sent);
      expect(outbox.dueEntries(), isEmpty);
    });

    test('Encolar dos veces el mismo id es no-op (dedup local)', () {
      final outbox = OutboxQueue(clock: clock);
      outbox.enqueue(envelope('msg-1'));
      outbox.enqueue(envelope('msg-1'));
      expect(outbox.length, 1);
    });

    test('Mensajes sin ack por más de maxAge fallan localmente', () {
      final outbox = OutboxQueue(
        maxAge: const Duration(minutes: 10),
        clock: clock,
      );
      outbox.enqueue(envelope('msg-old'));
      now = now.add(const Duration(minutes: 11));
      expect(outbox.dueEntries(), isEmpty);
      expect(
        outbox.byMessageId('msg-old')!.status,
        MessageDeliveryStatus.failed,
      );
    });

    test('14. El dedup del servidor rechaza el segundo envío del mismo id',
        () {
      final dedup = MessageDedup();
      expect(dedup.accept('msg-1'), isTrue, reason: 'primera vez: aceptado');
      expect(dedup.accept('msg-1'), isFalse, reason: 'reintento: duplicado');
      expect(dedup.accept('msg-2'), isTrue);
      expect(dedup.contains('msg-1'), isTrue);
    });

    test('El dedup recuerda dentro de una ventana acotada (LRU)', () {
      final dedup = MessageDedup(windowSize: 4);
      for (var i = 0; i < 6; i++) {
        dedup.accept('m$i');
      }
      expect(dedup.remembered, 4);
      expect(dedup.contains('m0'), isFalse, reason: 'evicted');
      expect(dedup.contains('m5'), isTrue);
    });
  });

  group('10. El servidor solo ve ciphertext', () {
    test('Un sobre válido lleva ciphertext y nada de texto plano', () {
      final e = envelope('msg-1');
      final wire = e.toWire();
      expect(wire['ciphertext'], 'Q0lQSEVSVEVYVA==');
      expect(
        containsPlaintextPayload(Map<String, dynamic>.from(wire)),
        isFalse,
      );
    });

    test('containsPlaintextPayload detecta fugas de texto plano', () {
      expect(containsPlaintextPayload({'text': 'hola'}), isTrue);
      expect(containsPlaintextPayload({'content': 'hola'}), isTrue);
      expect(containsPlaintextPayload({'body': 'hola'}), isTrue);
      expect(containsPlaintextPayload({'ciphertext': 'AAA'}), isFalse);
      expect(containsPlaintextPayload(<String, dynamic>{}), isFalse);
    });

    test('validateOutgoing rechaza sobres sin ciphertext', () {
      expect(MessageEnvelope.validateOutgoing(envelope('x')), isNull);
      const broken = MessageEnvelope(
        messageId: 'x',
        conversationId: '',
        senderDeviceId: 'd',
        ciphertextBase64: '',
        ciphertextHeaderType: '',
      );
      expect(MessageEnvelope.validateOutgoing(broken), 'PAYLOAD_INVALID');
    });

    test('tryParseInbound exige server_seq y campos del sobre', () {
      final parsed = MessageEnvelope.tryParseInbound(
        <String, dynamic>{
          'message_id': 'm1',
          'conversation_id': 'c1',
          'ciphertext': 'AA==',
          'header_type': 'dr.v1',
        },
        serverSeq: 7,
      );
      expect(parsed, isNotNull);
      expect(parsed!.serverSeq, 7);
      expect(
        MessageEnvelope.tryParseInbound(<String, dynamic>{'x': 1}, serverSeq: 1),
        isNull,
      );
    });
  });

  group('13. Orden — gaps, duplicados y fuera de orden', () {
    test('Secuencia continua se acepta sin gaps', () {
      final detector = SequenceGapDetector();
      for (var seq = 1; seq <= 5; seq++) {
        expect(
          detector.feed(
            conversationId: 'c1',
            messageId: 'm$seq',
            serverSeq: seq,
          ),
          SequenceGapDetector.FeedResult.accepted,
        );
      }
      expect(detector.lastContiguous('c1'), 5);
      expect(detector.hasPendingGap('c1'), isFalse);
    });

    test('Duplicado (mismo message_id) se descarta', () {
      final detector = SequenceGapDetector();
      detector.feed(conversationId: 'c1', messageId: 'm1', serverSeq: 1);
      expect(
        detector.feed(conversationId: 'c1', messageId: 'm1', serverSeq: 1),
        SequenceGapDetector.FeedResult.duplicate,
      );
    });

    test('Salto de secuencia marca GAP y buffera el mensaje', () {
      final detector = SequenceGapDetector();
      detector.feed(conversationId: 'c1', messageId: 'm1', serverSeq: 1);
      expect(
        detector.feed(conversationId: 'c1', messageId: 'm3', serverSeq: 3),
        SequenceGapDetector.FeedResult.gapDetected,
      );
      expect(detector.hasPendingGap('c1'), isTrue);
      expect(detector.lastContiguous('c1'), 1);
    });

    test('El mensaje faltante cierra el gap y el cursor avanza', () {
      final detector = SequenceGapDetector();
      detector.feed(conversationId: 'c1', messageId: 'm1', serverSeq: 1);
      detector.feed(conversationId: 'c1', messageId: 'm3', serverSeq: 3);
      final result = detector.feed(
        conversationId: 'c1',
        messageId: 'm2',
        serverSeq: 2,
      );
      // m2 es aceptado y arrastra al m3 buffereado: gap resuelto.
      expect(result, SequenceGapDetector.FeedResult.accepted);
      expect(detector.lastContiguous('c1'), 3);
      expect(detector.hasPendingGap('c1'), isFalse);
    });

    test('resynced fija el cursor autoritativo del servidor', () {
      final detector = SequenceGapDetector();
      detector.feed(conversationId: 'c1', messageId: 'm1', serverSeq: 1);
      detector.feed(conversationId: 'c1', messageId: 'm9', serverSeq: 9);
      detector.resynced('c1', newCursor: 9);
      expect(detector.lastContiguous('c1'), 9);
      expect(detector.hasPendingGap('c1'), isFalse);
    });
  });
}
