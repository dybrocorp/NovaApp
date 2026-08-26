// FASE 1 — §27/§28: una notificación NUNCA revela plaintext.
//
// Las push viajan por FCM/APNs (infraestructura de terceros, fuera del
// límite E2EE) y se pintan en una pantalla BLOQUEADA. Filtrar el
// contenido ahí anularía el cifrado extremo a extremo justo en el último
// paso y en el sitio más visible.
import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/messaging/service/notification_policy.dart';

void main() {
  const secreto = 'Transfiere 5000 euros a la cuenta ES91';

  group('§27 — El contenido nunca se filtra por defecto', () {
    test('senderOnly es el valor por defecto razonable y no revela el texto', () {
      final content = NotificationPolicy.build(
        level: NotificationPreviewLevel.senderOnly,
        senderDisplayName: 'Ana',
        messagePreview: secreto,
      );
      expect(content.body, contains('Ana'));
      expect(content.body, isNot(contains(secreto)));
      expect(content.body, isNot(contains('5000')));
    });

    test('none no revela ni el remitente ni el texto', () {
      final content = NotificationPolicy.build(
        level: NotificationPreviewLevel.none,
        senderDisplayName: 'Ana',
        messagePreview: secreto,
      );
      expect(content.body, 'Nuevo mensaje');
      expect(content.body, isNot(contains('Ana')));
      expect(content.body, isNot(contains(secreto)));
    });

    test('Sin nombre de remitente se degrada a un aviso genérico', () {
      final content = NotificationPolicy.build(
        level: NotificationPreviewLevel.senderOnly,
        messagePreview: secreto,
      );
      expect(content.body, 'Nuevo mensaje');
    });
  });

  group('§27 — La pantalla bloqueada degrada la vista previa', () {
    test('Con el dispositivo bloqueado NO se muestra el contenido', () {
      final content = NotificationPolicy.build(
        level: NotificationPreviewLevel.senderAndContent,
        senderDisplayName: 'Ana',
        messagePreview: secreto,
        deviceLocked: true,
      );
      expect(content.body, isNot(contains(secreto)),
          reason: 'cualquiera que sostenga el móvil vería el texto');
      expect(content.body, contains('Ana'));
    });

    test('Desbloqueado y con opt-in explícito sí se muestra', () {
      final content = NotificationPolicy.build(
        level: NotificationPreviewLevel.senderAndContent,
        senderDisplayName: 'Ana',
        messagePreview: 'hola',
        deviceLocked: false,
      );
      expect(content.title, 'Ana');
      expect(content.body, 'hola');
    });
  });

  group('§27 — La push originada en el servidor no puede llevar contenido', () {
    test('serverPush es siempre genérica', () {
      // El servidor sólo tiene ciphertext: esta ruta no puede filtrar
      // aunque alguien lo intentara.
      final content = NotificationPolicy.serverPush(conversationId: 'conv-1');
      expect(content.body, 'Nuevo mensaje');
      expect(content.title, NotificationPolicy.appName);
      expect(content.conversationId, 'conv-1');
    });
  });

  group('Robustez del renderizado', () {
    test('Un nombre con saltos de línea no puede forjar líneas extra', () {
      final content = NotificationPolicy.build(
        level: NotificationPreviewLevel.senderOnly,
        senderDisplayName: 'Ana\n\nSISTEMA: pulsa aquí',
        messagePreview: 'x',
      );
      expect(content.body, isNot(contains('\n')));
    });

    test('Una vista previa muy larga se trunca', () {
      final content = NotificationPolicy.build(
        level: NotificationPreviewLevel.senderAndContent,
        senderDisplayName: 'Ana',
        messagePreview: 'A' * 500,
      );
      expect(content.body.length, lessThanOrEqualTo(120));
      expect(content.body, endsWith('…'));
    });

    test('El id de conversación se conserva para el deep link', () {
      final content = NotificationPolicy.build(
        level: NotificationPreviewLevel.none,
        conversationId: 'conv-42',
      );
      // Es un id opaco: no revela contenido.
      expect(content.conversationId, 'conv-42');
    });
  });
}
