// FASE 0.5 — PASO 4 — §9 AUTORIZACIÓN y §23 SIGNALING:
// autenticado != autorizado; cada operación verifica permisos.
import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/socket/protocol/authorization_policy.dart';
import 'package:novaapp/core/socket/protocol/session_registry.dart';

void main() {
  late AuthorizationPolicy authz;
  late RegisteredSession aliceSession;
  late RegisteredSession bobSession;

  setUp(() {
    authz = AuthorizationPolicy();
    final registry = SessionRegistry();
    aliceSession = registry.create(
      socketKey: 'sock-alice',
      accountId: 'acc-alice',
      deviceId: 'dev-alice',
      novaId: 'NOVA-ALICE',
    );
    bobSession = registry.create(
      socketKey: 'sock-bob',
      accountId: 'acc-bob',
      deviceId: 'dev-bob',
      novaId: 'NOVA-BOB',
    );
    // Conversación entre Alice y Bob.
    authz.addConversationMember('conv-1', 'acc-alice');
    authz.addConversationMember('conv-1', 'acc-bob');
    // Carol NO es miembro.
    // Relación de contacto Alice<->Bob (llamadas permitidas).
    authz.addRelationship('acc-alice', 'acc-bob');
    // Carol puede ver la presencia de Alice (opt-in de privacidad).
    authz.allowPresence('acc-alice', 'acc-carol');
  });

  group('15. Autorización de mensajería', () {
    test('Miembro puede enviar a su conversación', () {
      expect(
        authz.canSendMessage(session: aliceSession, conversationId: 'conv-1'),
        AuthzDecision.allow,
      );
    });

    test('NO miembro NO puede enviar (aunque esté autenticado)', () {
      final carolSession = SessionRegistry().create(
        socketKey: 'sock-carol',
        accountId: 'acc-carol',
        deviceId: 'dev-carol',
        novaId: 'NOVA-CAROL',
      );
      expect(
        authz.canSendMessage(session: carolSession, conversationId: 'conv-1'),
        AuthzDecision.denyNotAuthorized,
      );
    });

    test('Sin sesión no se puede enviar nada', () {
      expect(
        authz.canSendMessage(session: null, conversationId: 'conv-1'),
        AuthzDecision.denyNotAuthenticated,
      );
    });

    test('Leer eventos de una conversación ajena es denegado', () {
      expect(
        authz.canReadConversation(session: bobSession, conversationId: 'conv-x'),
        AuthzDecision.denyNotAuthorized,
      );
    });
  });

  group('20. Autorización de señalización (llamadas)', () {
    test('Contactos pueden intercambiar signaling', () {
      expect(
        authz.canSignalCall(session: aliceSession, peerAccountId: 'acc-bob'),
        AuthzDecision.allow,
      );
      expect(
        authz.canSignalCall(session: bobSession, peerAccountId: 'acc-alice'),
        AuthzDecision.allow,
      );
    });

    test('Un desconocido NO puede hacer signaling (call.offer denegado)', () {
      expect(
        authz.canSignalCall(session: aliceSession, peerAccountId: 'acc-eve'),
        AuthzDecision.denyNotAuthorized,
      );
    });

    test('Sin sesión no hay signaling', () {
      expect(
        authz.canSignalCall(session: null, peerAccountId: 'acc-bob'),
        AuthzDecision.denyNotAuthenticated,
      );
    });
  });

  group('16 (presencia). Presencia solo para audiencia autorizada', () {
    test('El viewer autorizado ve la presencia', () {
      expect(
        authz.canViewPresence(
          session: SessionRegistry().create(
            socketKey: 'sock-carol',
            accountId: 'acc-carol',
            deviceId: 'dev-carol',
            novaId: 'NOVA-CAROL',
          ),
          subjectAccountId: 'acc-alice',
        ),
        AuthzDecision.allow,
      );
    });

    test('Un usuario cualquiera NO ve la presencia (no broadcast global)', () {
      expect(
        authz.canViewPresence(session: bobSession, subjectAccountId: 'acc-alice'),
        AuthzDecision.denyNotAuthorized,
      );
    });
  });

  group('Gestión de dispositivos', () {
    test('Solo la propia cuenta gestiona sus dispositivos', () {
      expect(
        authz.canManageDevices(
          session: aliceSession,
          targetAccountId: 'acc-alice',
        ),
        AuthzDecision.allow,
      );
      expect(
        authz.canManageDevices(
          session: bobSession,
          targetAccountId: 'acc-alice',
        ),
        AuthzDecision.denyNotAuthorized,
      );
    });
  });
}
