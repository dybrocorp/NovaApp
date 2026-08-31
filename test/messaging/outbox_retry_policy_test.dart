// FASE 1.1 §7 — Outbox persistente: SEMÁFORO DE REINTENTOS probado.
//
// Cubre el hueco de tests que la auditoría de FASE 1.1 detectó en main:
// `OutboxStore` (retry exponencial, límite de intentos, deduplicación,
// caducidad por edad, ACK que detiene el reintento y estados forward-only)
// NO tenía ningún test específico. Este archivo lo cierra (a nivel de
// unidad, sobre sqflite_common_ffi, sin dispositivo).
//
// NOT RUN en el entorno de autoría — Flutter SDK no disponible
// (docs/PHASE1_1_VALIDATION_REPORT.md). Ejecutar con `flutter test`.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show inMemoryDatabasePath;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:novaapp/core/messaging/model/delivery_state.dart';
import 'package:novaapp/core/messaging/model/message_envelope_v1.dart';
import 'package:novaapp/core/messaging/model/message_ids.dart';
import 'package:novaapp/core/messaging/model/message_type.dart';
import 'package:novaapp/core/messaging/store/messaging_database.dart';
import 'package:novaapp/core/messaging/store/outbox_store.dart';

MessageEnvelopeV1 _env(String messageId, {String device = 'devB1'}) =>
    MessageEnvelopeV1(
      messageId: MessageId(messageId),
      conversationId: const ConversationId('conv-ob'),
      senderAccountId: const AccountId('alice'),
      senderDeviceId: const DeviceId('devA'),
      recipientDeviceId: DeviceId(device),
      messageType: MessageType.text,
      ciphertextBase64: 'Y2lwaGVy',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late MessagingDatabase messaging;
  late int t;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(),
    );
    messaging = MessagingDatabase(database: db);
    await messaging.database;
  });

  setUp(() async {
    await db.delete('msg_outbox');
    t = 1000;
  });

  tearDownAll(() async {
    await db.close();
  });

  OutboxStore store({
    int maxAttempts = 8,
    Duration baseBackoff = const Duration(milliseconds: 100),
    Duration maxBackoff = const Duration(seconds: 60),
    Duration maxAge = const Duration(days: 7),
  }) =>
      OutboxStore(
        messaging,
        maxAttempts: maxAttempts,
        baseBackoff: baseBackoff,
        maxBackoff: maxBackoff,
        maxAge: maxAge,
        clock: () => t,
      );

  Future<Map<String, Object?>?> row(String messageId, {String device = 'devB1'}) async {
    final rows = await db.query(
      'msg_outbox',
      where: 'message_id = ? AND recipient_device_id = ?',
      whereArgs: [messageId, device],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  test('debido: entra en cola y sale inmediatamente una sola vez', () async {
    final s = store();
    await s.enqueue(_env('m1'));
    final due = await s.dueEntries();
    expect(due, hasLength(1));
    expect(due.single.attempts, 0);
    expect(due.single.state, DeliveryState.queued);
  });

  test('backoff exponencial: no hay reintento antes de su ventana', () async {
    final s = store(maxAttempts: 3);
    await s.enqueue(_env('m1'));

    // intento 1 -> espera base (100 ms)
    await s.markAttempt(const MessageId('m1'), const DeviceId('devB1'));
    expect(await s.dueEntries(), isEmpty, reason: 'hot retry prohibido');
    t += 99;
    expect(await s.dueEntries(), isEmpty);
    t += 1; // exactamente la ventana: due
    expect(await s.dueEntries(), hasLength(1));

    // intento 2 -> espera 2x (duplicada)
    await s.markAttempt(const MessageId('m1'), const DeviceId('devB1'));
    final r = await row('m1');
    expect(r!['next_attempt_at_ms'], t + 200);
    t += 199;
    expect(await s.dueEntries(), isEmpty);

    // intento 3 -> alcanza maxAttempts: TERMINAL failed, nunca más due
    t += 1;
    await s.markAttempt(const MessageId('m1'), const DeviceId('devB1'));
    final dead = await row('m1');
    expect(dead!['state'], DeliveryState.failed.name);
    expect(dead['last_error'], 'MAX_ATTEMPTS');
    t += 100000;
    expect(await s.dueEntries(), isEmpty, reason: 'un failed terminal NO se reanima');
  });

  test('ACK detiene el reintento y guarda server_seq; estados forward-only',
      () async {
    final s = store();
    await s.enqueue(_env('m2'));
    await s.markAttempt(const MessageId('m2'), const DeviceId('devB1'));
    await s.markAcked(const MessageId('m2'), const DeviceId('devB1'),
        serverSeq: 7);
    expect(await s.dueEntries(), isEmpty);
    final r = await row('m2');
    expect(r!['state'], DeliveryState.sent.name);
    expect(r['server_seq'], 7);

    await s.markState(
        const MessageId('m2'), const DeviceId('devB1'), DeliveryState.read);
    await s.markState(const MessageId('m2'), const DeviceId('devB1'),
        DeliveryState.delivered);
    // Un delivered tardío NUNCA revierte un read (forward-only).
    expect((await row('m2'))!['state'], DeliveryState.read.name);
  });

  test('dedup: re-enqueue del mismo (message_id, dispositivo) no duplica '
      'ni resucita filas fallidas', () async {
    final s = store();
    await s.enqueue(_env('m3'));
    await s.enqueue(_env('m3')); // ignorado (no resetea attempts)
    final rows = await db.query('msg_outbox', where: "message_id = 'm3'");
    expect(rows, hasLength(1));

    await s.markPermanentFailure(
        const MessageId('m3'), const DeviceId('devB1'), 'FORBIDDEN');
    await s.enqueue(_env('m3'));
    final dead = await row('m3');
    expect(dead!['state'], DeliveryState.failed.name,
        reason: 'enqueue NO resucita un fallo permanente (§12)');
    expect(dead['last_error'], 'FORBIDDEN');
  });

  test('maxAge: caducidad dura del Outbox (nunca cola eterna)', () async {
    final s = store(maxAge: const Duration(seconds: 10)));
    await s.enqueue(_env('old'));
    t += 11 * 1000;
    expect(await s.dueEntries(), isEmpty); // _expireStale corre dentro de due
    final r = await row('old');
    expect(r!['state'], DeliveryState.failed.name);
    expect(r['last_error'], 'EXPIRED');
  });

  test('fan-out: dos copas del mismo mensaje se reintentan de forma '
      'independiente por dispositivo', () async {
    final s = store(maxAttempts: 2);
    await s.enqueue(_env('shared', device: 'devB1'));
    await s.enqueue(_env('shared', device: 'devB2'));

    await s.markAttempt(const MessageId('shared'), const DeviceId('devB1'));
    await s.markAttempt(const MessageId('shared'), const DeviceId('devB1'));
    // devB1 agotó maxAttempts -> terminal; devB2 sigue viva.
    expect((await row('shared', device: 'devB1'))!['state'],
        DeliveryState.failed.name);
    expect((await row('shared', device: 'devB2'))!['state'],
        DeliveryState.queued.name);
    await s.markAcked(const MessageId('shared'), const DeviceId('devB2'),
        serverSeq: 3);
    expect((await row('shared', device: 'devB2'))!['state'],
        DeliveryState.sent.name,
        reason: 'el ACK del otro dispositivo NO se propaga');
  });
}
