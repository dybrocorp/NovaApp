// FASE 1 — Modelo de mensaje: envelope, body, tipos y estados.
//
// Cubre §5 (nada de plaintext en el modelo persistido), §6 (tipos
// extensibles), §8 (envelope versionado con separación routing/payload)
// y §17 (SENT/DELIVERED/READ separados y por dispositivo).
import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/messaging/model/delivery_state.dart';
import 'package:novaapp/core/messaging/model/media_reference.dart';
import 'package:novaapp/core/messaging/model/message_body.dart';
import 'package:novaapp/core/messaging/model/message_envelope_v1.dart';
import 'package:novaapp/core/messaging/model/message_ids.dart';
import 'package:novaapp/core/messaging/model/message_type.dart';

void main() {
  MessageEnvelopeV1 envelope({String type = 'text'}) => MessageEnvelopeV1(
        messageId: const MessageId('msg-1'),
        conversationId: const ConversationId('conv-1'),
        senderAccountId: const AccountId('acc-a'),
        senderDeviceId: const DeviceId('dev-a1'),
        recipientDeviceId: const DeviceId('dev-b1'),
        messageType: MessageType.fromWireTag(type) ?? MessageType.text,
        ciphertextBase64: 'Q0lQSEVSVEVYVA==',
      );

  group('§4 — Los identificadores no son intercambiables', () {
    test('Los ids de conversación son aleatorios, no derivados', () {
      final a = ConversationId.generate();
      final b = ConversationId.generate();
      expect(a.value, isNot(equals(b.value)));
      // No debe poder deducirse de los participantes: si fuera derivado,
      // cualquiera podría sondear si dos cuentas hablan entre sí.
      expect(a.value.contains('acc-'), isFalse);
    });

    test('Los message_id generados son únicos', () {
      final ids = List.generate(100, (_) => MessageId.generate().value);
      expect(ids.toSet().length, 100);
    });

    test('tryParse rechaza vacíos y espacios', () {
      expect(AccountId.tryParse(''), isNull);
      expect(AccountId.tryParse('   '), isNull);
      expect(AccountId.tryParse(null), isNull);
      expect(AccountId.tryParse(' acc-1 ')?.value, 'acc-1');
    });
  });

  group('§5/§8 — El envelope separa routing de payload cifrado', () {
    test('toWire no contiene NINGÚN campo de texto en claro', () {
      final wire = envelope().toWire();
      for (final forbidden in ['text', 'plaintext', 'content', 'body', 'message']) {
        expect(wire.containsKey(forbidden), isFalse,
            reason: 'el servidor nunca debe recibir "$forbidden"');
      }
      expect(wire['ciphertext'], isNotEmpty);
    });

    test('El envelope lleva su versión (permite evolución)', () {
      expect(envelope().toWire()['envelope_version'], kEnvelopeVersionV1);
    });

    test('El envelope va dirigido a un dispositivo concreto', () {
      expect(envelope().toWire()['recipient_device_id'], 'dev-b1');
    });

    test('validateOutgoing rechaza un envelope sin ciphertext', () {
      const invalid = MessageEnvelopeV1(
        messageId: MessageId('m'),
        conversationId: ConversationId('c'),
        senderAccountId: AccountId('a'),
        senderDeviceId: DeviceId('d'),
        recipientDeviceId: DeviceId('r'),
        messageType: MessageType.text,
        ciphertextBase64: '',
      );
      expect(MessageEnvelopeV1.validateOutgoing(invalid), 'PAYLOAD_INVALID');
    });

    test('validateOutgoing acepta un envelope correcto', () {
      expect(MessageEnvelopeV1.validateOutgoing(envelope()), isNull);
    });

    test('tryParseInbound rechaza un payload sin ciphertext', () {
      expect(
        MessageEnvelopeV1.tryParseInbound(<String, dynamic>{
          'message_id': 'm',
          'conversation_id': 'c',
          'sender_account_id': 'a',
          'sender_device_id': 'd',
        }),
        isNull,
      );
    });

    test('Un tipo desconocido no rompe al cliente antiguo', () {
      // Compatibilidad hacia adelante: un cliente nuevo puede enviar un
      // tipo que este build no conoce; debe degradar, no lanzar.
      final parsed = MessageEnvelopeV1.tryParseInbound(<String, dynamic>{
        'message_id': 'm',
        'conversation_id': 'c',
        'sender_account_id': 'a',
        'sender_device_id': 'd',
        'ciphertext': 'Q0k=',
        'message_type': 'holograma_2030',
      });
      expect(parsed, isNotNull);
      expect(parsed!.messageType, MessageType.system);
    });
  });

  group('§6 — Los tipos son extensibles sin reescribir Message', () {
    test('Las etiquetas de cable son estables', () {
      expect(MessageType.voiceNote.wireTag, 'voice_note');
      expect(MessageType.text.wireTag, 'text');
      expect(MessageType.fromWireTag('voice_note'), MessageType.voiceNote);
    });

    test('isMedia clasifica correctamente', () {
      expect(MessageType.image.isMedia, isTrue);
      expect(MessageType.voiceNote.isMedia, isTrue);
      expect(MessageType.text.isMedia, isFalse);
      expect(MessageType.reaction.isMedia, isFalse);
    });

    test('isMutation distingue las que alteran otro mensaje', () {
      expect(MessageType.edit.isMutation, isTrue);
      expect(MessageType.deletion.isMutation, isTrue);
      expect(MessageType.reaction.isMutation, isTrue);
      expect(MessageType.text.isMutation, isFalse);
    });
  });

  group('§20/§21 — El grafo de respuestas y reacciones va CIFRADO', () {
    test('reply_to viaja dentro del body, no en el envelope', () {
      final body = MessageBody.reply(
        quoted: const MessageId('msg-original'),
        value: 'de acuerdo',
      );
      expect(body.replyToMessageId?.value, 'msg-original');
      // El envelope no lo expone: quién responde a quién es contenido.
      expect(envelope().toWire().containsKey('reply_to'), isFalse);
    });

    test('Una reacción se serializa y recupera intacta', () {
      final body = MessageBody.reaction(
        target: const MessageId('msg-7'),
        emoji: '👍',
      );
      final restored = MessageBody.decode(body.encode())!;
      expect(restored.type, MessageType.reaction);
      expect(restored.reactionTargetMessageId?.value, 'msg-7');
      expect(restored.reactionEmoji, '👍');
      expect(restored.isReactionRemoval, isFalse);
    });

    test('Una reacción vacía significa "quitar"', () {
      final body = MessageBody.reactionRemoval(target: const MessageId('msg-7'));
      expect(MessageBody.decode(body.encode())!.isReactionRemoval, isTrue);
    });
  });

  group('Compatibilidad hacia adelante del body', () {
    test('Los campos desconocidos se conservan al reserializar', () {
      const raw = '{"type":"text","text":"hola","campo_futuro":42}';
      final body = MessageBody.decode(raw)!;
      expect(body.text, 'hola');
      expect(body.extra?['campo_futuro'], 42);
      // Reserializar no debe perder lo que un cliente nuevo añadió.
      expect(MessageBody.decode(body.encode())!.extra?['campo_futuro'], 42);
    });

    test('Un JSON corrupto devuelve null, no una excepción', () {
      expect(MessageBody.decode('{no es json'), isNull);
      expect(MessageBody.decode('[]'), isNull);
    });
  });

  group('§17 — SENT, DELIVERED y READ son estados distintos', () {
    test('Los estados avanzan sólo hacia adelante', () {
      var state = DeliveryState.queued;
      state = DeliveryStateMachine.apply(state, DeliveryState.sent);
      expect(state, DeliveryState.sent);
      state = DeliveryStateMachine.apply(state, DeliveryState.read);
      expect(state, DeliveryState.read);
      // Un delivered tardío NO debe degradar un read ya aplicado.
      state = DeliveryStateMachine.apply(state, DeliveryState.delivered);
      expect(state, DeliveryState.read);
    });

    test('Un fallo no borra una entrega ya confirmada', () {
      final state = DeliveryStateMachine.apply(
        DeliveryState.delivered,
        DeliveryState.failed,
      );
      expect(state, DeliveryState.delivered);
    });

    test('Un mensaje fallido se recupera si la red lo confirma después', () {
      final state = DeliveryStateMachine.apply(
        DeliveryState.failed,
        DeliveryState.sent,
      );
      expect(state, DeliveryState.sent);
    });

    test('El agregado es el MÍNIMO entre dispositivos, no el máximo', () {
      // Con tres dispositivos, uno que ya leyó no puede hacer que el
      // mensaje aparezca como "leído" para toda la cuenta.
      const summary = MessageDeliverySummary(<DeviceDeliveryState>[
        DeviceDeliveryState(deviceId: DeviceId('d1'), state: DeliveryState.read),
        DeviceDeliveryState(deviceId: DeviceId('d2'), state: DeliveryState.delivered),
        DeviceDeliveryState(deviceId: DeviceId('d3'), state: DeliveryState.sent),
      ]);
      expect(summary.aggregate, DeliveryState.sent);
      expect(summary.anyReached(DeliveryState.read), isTrue);
    });

    test('El estado se actualiza por dispositivo', () {
      const summary = MessageDeliverySummary(<DeviceDeliveryState>[
        DeviceDeliveryState(deviceId: DeviceId('d1'), state: DeliveryState.sent),
        DeviceDeliveryState(deviceId: DeviceId('d2'), state: DeliveryState.sent),
      ]);
      final updated = summary.update(const DeviceId('d1'), DeliveryState.read);
      expect(updated.aggregate, DeliveryState.sent, reason: 'd2 sigue en sent');
      expect(
        updated.perDevice.firstWhere((e) => e.deviceId.value == 'd1').state,
        DeliveryState.read,
      );
    });
  });

  group('§23/§24 — Referencia a objeto multimedia cifrado', () {
    const reference = MediaReference(
      objectId: 'obj-random-123',
      keyBase64: 'CLAVE_SUPER_SECRETA_DEL_OBJETO',
      nonceBase64: 'bm9uY2U=',
      sha256Base64: 'ZGlnZXN0',
      sizeBytes: 2048,
      mimeType: 'image/jpeg',
    );

    test('toString NUNCA expone la clave del objeto', () {
      // Una línea de log con la clave entregaría el objeto entero.
      expect(reference.toString(), isNot(contains('CLAVE_SUPER_SECRETA')));
      expect(reference.toString(), contains('[REDACTED]'));
    });

    test('La referencia se serializa y recupera intacta', () {
      final restored = MediaReference.fromJson(reference.toJson())!;
      expect(restored.objectId, 'obj-random-123');
      expect(restored.keyBase64, 'CLAVE_SUPER_SECRETA_DEL_OBJETO');
      expect(restored.sizeBytes, 2048);
      expect(restored.cipher, kMediaCipherAesGcm);
    });

    test('La clave viaja DENTRO del body cifrado, no en el envelope', () {
      final body = MessageBody.media(
        type: MessageType.image,
        reference: reference,
        caption: 'foto',
      );
      // Está en el body (que se cifra)…
      expect(body.encode(), contains('CLAVE_SUPER_SECRETA'));
      // …y nunca en la metadata de enrutado que ve el servidor.
      expect(envelope().toWire().toString(), isNot(contains('CLAVE_SUPER_SECRETA')));
    });

    test('Una referencia incompleta se rechaza', () {
      expect(MediaReference.fromJson(<String, dynamic>{'object_id': 'x'}), isNull);
    });
  });
}
