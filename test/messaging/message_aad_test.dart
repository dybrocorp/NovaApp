// FASE 1 — §9 / §38: la AAD canónica liga el contexto de enrutado.
//
// El hallazgo del análisis (docs/PHASE1_MESSAGE_ARCHITECTURE.md §3.1): la
// AAD del Double Ratchet sólo cubre la cabecera del ratchet, de modo que
// un servidor comprometido puede reenrutar un sobre auténtico a otra
// conversación o reatribuirlo a otro remitente sin romper el AEAD.
//
// Estas pruebas fijan la propiedad que lo impide: cambiar CUALQUIER campo
// ligado produce una AAD distinta y, por tanto, un fallo de autenticación
// en el destinatario.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/messaging/crypto/message_aad.dart';

void main() {
  Map<String, dynamic> baseFields() => <String, dynamic>{
        'conversationId': 'conv-1',
        'senderAccountId': 'acc-a',
        'senderDeviceId': 'dev-a1',
        'recipientDeviceId': 'dev-b1',
        'messageId': 'msg-1',
        'messageType': 'text',
        'envelopeVersion': 1,
      };

  List<int> buildFrom(Map<String, dynamic> f) => MessageAad.build(
        conversationId: f['conversationId'] as String,
        senderAccountId: f['senderAccountId'] as String,
        senderDeviceId: f['senderDeviceId'] as String,
        recipientDeviceId: f['recipientDeviceId'] as String,
        messageId: f['messageId'] as String,
        messageType: f['messageType'] as String,
        envelopeVersion: f['envelopeVersion'] as int,
      );

  group('§9 — La AAD liga todo el contexto de enrutado', () {
    test('Es determinista: los mismos campos producen los mismos bytes', () {
      expect(buildFrom(baseFields()), equals(buildFrom(baseFields())));
    });

    test('Incluye la etiqueta de versión', () {
      final aad = utf8.decode(buildFrom(baseFields()));
      expect(aad, startsWith(kMessageAadVersion));
    });

    // El corazón de §9: cada campo, por separado, debe alterar la AAD.
    for (final field in <String>[
      'conversationId',
      'senderAccountId',
      'senderDeviceId',
      'recipientDeviceId',
      'messageId',
      'messageType',
    ]) {
      test('Cambiar $field cambia la AAD', () {
        final original = buildFrom(baseFields());
        final tampered = baseFields()..[field] = 'ATACANTE';
        expect(
          buildFrom(tampered),
          isNot(equals(original)),
          reason: 'un servidor no debe poder reescribir $field en silencio',
        );
      });
    }

    test('Cambiar la versión del sobre cambia la AAD (anti-downgrade)', () {
      final original = buildFrom(baseFields());
      final downgraded = baseFields()..['envelopeVersion'] = 2;
      expect(buildFrom(downgraded), isNot(equals(original)));
    });
  });

  group('§9 — La codificación es inyectiva (sin ambigüedad)', () {
    test('No se puede desplazar el límite entre dos campos', () {
      // Con un separador imprimible, mover texto de un campo al
      // siguiente podría producir los mismos bytes. Con NUL, no.
      final a = MessageAad.build(
        conversationId: 'conv',
        senderAccountId: 'a|b',
        senderDeviceId: 'dev',
        recipientDeviceId: 'rcp',
        messageId: 'msg',
        messageType: 'text',
        envelopeVersion: 1,
      );
      final b = MessageAad.build(
        conversationId: 'conv',
        senderAccountId: 'a',
        senderDeviceId: 'b|dev',
        recipientDeviceId: 'rcp',
        messageId: 'msg',
        messageType: 'text',
        envelopeVersion: 1,
      );
      expect(a, isNot(equals(b)));
    });

    test('Un campo con NUL se rechaza (falla cerrado)', () {
      expect(
        () => MessageAad.build(
          conversationId: 'conv\u0000falso',
          senderAccountId: 'acc',
          senderDeviceId: 'dev',
          recipientDeviceId: 'rcp',
          messageId: 'msg',
          messageType: 'text',
          envelopeVersion: 1,
        ),
        throwsA(isA<MessageAadError>()),
        reason: 'debe rechazar, no degradar la ligadura en silencio',
      );
    });

    test('Un campo vacío se rechaza', () {
      expect(
        () => MessageAad.build(
          conversationId: '',
          senderAccountId: 'acc',
          senderDeviceId: 'dev',
          recipientDeviceId: 'rcp',
          messageId: 'msg',
          messageType: 'text',
          envelopeVersion: 1,
        ),
        throwsA(isA<MessageAadError>()),
      );
    });
  });

  group('§38 — Escenarios concretos de ataque', () {
    test('Reenrutar a otra conversación rompe la ligadura', () {
      final legit = buildFrom(baseFields());
      final rerouted = baseFields()..['conversationId'] = 'conv-victima';
      expect(buildFrom(rerouted), isNot(equals(legit)));
    });

    test('Reatribuir el mensaje a otro remitente rompe la ligadura', () {
      final legit = buildFrom(baseFields());
      final reattributed = baseFields()..['senderAccountId'] = 'acc-suplantada';
      expect(buildFrom(reattributed), isNot(equals(legit)));
    });

    test('Reenviar la copia de un dispositivo a otro rompe la ligadura', () {
      // El fan-out por dispositivo (§15) hace que cada copia esté ligada
      // a SU dispositivo destino: reproducir la de B1 hacia B2 falla.
      final forB1 = buildFrom(baseFields());
      final forB2 = baseFields()..['recipientDeviceId'] = 'dev-b2';
      expect(buildFrom(forB2), isNot(equals(forB1)));
    });

    test('Cambiar el tipo de mensaje rompe la ligadura', () {
      // Evita convertir un 'text' en un 'deletion' que borraría otro
      // mensaje al aplicarse.
      final asText = buildFrom(baseFields());
      final asDeletion = baseFields()..['messageType'] = 'deletion';
      expect(buildFrom(asDeletion), isNot(equals(asText)));
    });
  });

  group('Seguridad del formateo de depuración', () {
    test('debugFormat no expone material sensible', () {
      final rendered = MessageAad.debugFormat(buildFrom(baseFields()));
      // La AAD es metadata de enrutado que el servidor ya ve; no debe
      // contener claves ni contenido.
      expect(rendered, contains('conv-1'));
      expect(rendered, isNot(contains('\u0000')));
    });
  });
}
