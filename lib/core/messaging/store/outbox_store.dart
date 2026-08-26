/// Persistent Outbox (§10, §11, §12).
///
/// Replaces the in-memory queue in `offline_sync_service.dart`, which lost
/// every pending message when the app was killed. §11 requires:
///
///   create message -> save locally -> lose Internet -> regain -> send -> ACK
///
/// That only holds if the queue survives process death, so it lives in
/// SQLite and every state transition is written before it is acted on.
///
/// ## Retry policy (§12)
///
/// Exponential backoff with a hard attempt cap. §12 is explicit: "NO
/// enviar infinitamente un mensaje fallido". After [maxAttempts] the row
/// becomes `failed` — terminal, never retried, surfaced to the user.
///
/// Backoff: 1s, 2s, 4s, 8s, 16s, capped at 60s. Deterministic jitter is
/// applied by the caller's scheduler; the store only records the
/// earliest next attempt.
///
/// ## Idempotency
///
/// The primary key is (message_id, recipient_device_id). Re-enqueueing the
/// same pair is a no-op, and every retry reuses the SAME message_id so the
/// server deduplicates instead of storing a second copy.
library;

import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';

import '../model/delivery_state.dart';
import '../model/message_envelope_v1.dart';
import '../model/message_ids.dart';
import '../model/message_type.dart';
import 'messaging_database.dart';

/// One queued envelope plus its retry bookkeeping.
class OutboxRecord {
  const OutboxRecord({
    required this.envelope,
    required this.state,
    required this.attempts,
    required this.nextAttemptAtMs,
    required this.enqueuedAtMs,
    this.lastError,
    this.serverSeq,
  });

  final MessageEnvelopeV1 envelope;
  final DeliveryState state;
  final int attempts;
  final int nextAttemptAtMs;
  final int enqueuedAtMs;
  final String? lastError;
  final int? serverSeq;

  static OutboxRecord fromRow(Map<String, Object?> row) => OutboxRecord(
        envelope: MessageEnvelopeV1(
          messageId: MessageId(row['message_id'] as String),
          conversationId: ConversationId(row['conversation_id'] as String),
          senderAccountId: AccountId(row['sender_account_id'] as String),
          senderDeviceId: DeviceId(row['sender_device_id'] as String),
          recipientDeviceId: DeviceId(row['recipient_device_id'] as String),
          messageType:
              MessageType.fromWireTag(row['message_type'] as String?) ?? MessageType.text,
          ciphertextBase64: row['ciphertext'] as String,
          ciphertextHeaderType: row['header_type'] as String,
          envelopeVersion: (row['envelope_version'] as int?) ?? kEnvelopeVersionV1,
          clientTimestampMs: row['client_ts_ms'] as int?,
          expiresAtMs: row['expires_at_ms'] as int?,
          serverSeq: row['server_seq'] as int?,
        ),
        state: DeliveryState.fromName(row['state'] as String?),
        attempts: (row['attempts'] as int?) ?? 0,
        nextAttemptAtMs: (row['next_attempt_at_ms'] as int?) ?? 0,
        enqueuedAtMs: (row['enqueued_at_ms'] as int?) ?? 0,
        lastError: row['last_error'] as String?,
        serverSeq: row['server_seq'] as int?,
      );
}

class OutboxStore {
  OutboxStore(
    this._db, {
    this.maxAttempts = 8,
    this.baseBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 60),
    this.maxAge = const Duration(days: 7),
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final MessagingDatabase _db;

  /// Hard cap: after this many failures the message is terminal (§12).
  final int maxAttempts;
  final Duration baseBackoff;
  final Duration maxBackoff;

  /// Messages older than this are abandoned even if attempts remain —
  /// a week-old queued message is almost never worth delivering.
  final Duration maxAge;

  final int Function() _clock;

  /// Enqueues one envelope. Idempotent per (message_id, device).
  Future<void> enqueue(MessageEnvelopeV1 envelope) async {
    final db = await _db.database;
    final now = _clock();
    await db.insert(
      'msg_outbox',
      <String, Object?>{
        'message_id': envelope.messageId.value,
        'recipient_device_id': envelope.recipientDeviceId.value,
        'conversation_id': envelope.conversationId.value,
        'sender_account_id': envelope.senderAccountId.value,
        'sender_device_id': envelope.senderDeviceId.value,
        'message_type': envelope.messageType.wireTag,
        'envelope_version': envelope.envelopeVersion,
        'ciphertext': envelope.ciphertextBase64,
        'header_type': envelope.ciphertextHeaderType,
        'client_ts_ms': envelope.clientTimestampMs,
        'expires_at_ms': envelope.expiresAtMs,
        'state': DeliveryState.queued.name,
        'attempts': 0,
        'next_attempt_at_ms': now,
        'enqueued_at_ms': now,
      },
      // A duplicate enqueue must NOT reset attempts or resurrect a
      // failed row, so ignore instead of replace.
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> enqueueAll(Iterable<MessageEnvelopeV1> envelopes) async {
    for (final envelope in envelopes) {
      await enqueue(envelope);
    }
  }

  /// Envelopes that should be transmitted right now: queued, past their
  /// backoff deadline, and not expired.
  Future<List<OutboxRecord>> dueEntries({int limit = 50}) async {
    final db = await _db.database;
    final now = _clock();
    await _expireStale(now);
    final rows = await db.query(
      'msg_outbox',
      where: 'state IN (?, ?) AND next_attempt_at_ms <= ?',
      whereArgs: [DeliveryState.queued.name, DeliveryState.sending.name, now],
      orderBy: 'enqueued_at_ms ASC',
      limit: limit,
    );
    return rows.map(OutboxRecord.fromRow).toList();
  }

  /// Marks a transmission attempt and schedules the next one.
  ///
  /// Recording the backoff BEFORE the send means a crash mid-send cannot
  /// produce a hot retry loop on restart.
  Future<void> markAttempt(MessageId messageId, DeviceId deviceId) async {
    final db = await _db.database;
    final now = _clock();
    final rows = await db.query(
      'msg_outbox',
      columns: ['attempts'],
      where: 'message_id = ? AND recipient_device_id = ?',
      whereArgs: [messageId.value, deviceId.value],
      limit: 1,
    );
    if (rows.isEmpty) return;

    final attempts = ((rows.first['attempts'] as int?) ?? 0) + 1;
    if (attempts >= maxAttempts) {
      // Terminal: never retried again (§12).
      await db.update(
        'msg_outbox',
        <String, Object?>{
          'attempts': attempts,
          'state': DeliveryState.failed.name,
          'last_error': 'MAX_ATTEMPTS',
        },
        where: 'message_id = ? AND recipient_device_id = ?',
        whereArgs: [messageId.value, deviceId.value],
      );
      return;
    }

    await db.update(
      'msg_outbox',
      <String, Object?>{
        'attempts': attempts,
        'state': DeliveryState.sending.name,
        'next_attempt_at_ms': now + _backoffMs(attempts),
      },
      where: 'message_id = ? AND recipient_device_id = ?',
      whereArgs: [messageId.value, deviceId.value],
    );
  }

  /// Server acknowledged receipt (SENT — not delivered, §17).
  Future<void> markAcked(
    MessageId messageId,
    DeviceId deviceId, {
    int? serverSeq,
  }) async {
    final db = await _db.database;
    await db.update(
      'msg_outbox',
      <String, Object?>{
        'state': DeliveryState.sent.name,
        'acked_at_ms': _clock(),
        'server_seq': serverSeq,
        'last_error': null,
      },
      where: 'message_id = ? AND recipient_device_id = ?',
      whereArgs: [messageId.value, deviceId.value],
    );
  }

  /// Applies a delivery/read receipt from the recipient device.
  Future<void> markState(
    MessageId messageId,
    DeviceId deviceId,
    DeliveryState next,
  ) async {
    final db = await _db.database;
    final rows = await db.query(
      'msg_outbox',
      columns: ['state'],
      where: 'message_id = ? AND recipient_device_id = ?',
      whereArgs: [messageId.value, deviceId.value],
      limit: 1,
    );
    if (rows.isEmpty) return;
    // Forward-only: a late `delivered` must not undo `read`.
    final merged = DeliveryStateMachine.apply(
      DeliveryState.fromName(rows.first['state'] as String?),
      next,
    );
    await db.update(
      'msg_outbox',
      <String, Object?>{'state': merged.name},
      where: 'message_id = ? AND recipient_device_id = ?',
      whereArgs: [messageId.value, deviceId.value],
    );
  }

  /// Permanent failure (e.g. FORBIDDEN): terminal, no retry (§12).
  Future<void> markPermanentFailure(
    MessageId messageId,
    DeviceId deviceId,
    String reason,
  ) async {
    final db = await _db.database;
    await db.update(
      'msg_outbox',
      <String, Object?>{'state': DeliveryState.failed.name, 'last_error': reason},
      where: 'message_id = ? AND recipient_device_id = ?',
      whereArgs: [messageId.value, deviceId.value],
    );
  }

  /// User-initiated cancellation (§12).
  Future<void> cancel(MessageId messageId) async {
    final db = await _db.database;
    await db.delete(
      'msg_outbox',
      where: 'message_id = ? AND state IN (?, ?)',
      whereArgs: [messageId.value, DeliveryState.queued.name, DeliveryState.sending.name],
    );
  }

  /// Aggregate per-device state of one message (§17).
  Future<MessageDeliverySummary> deliverySummary(MessageId messageId) async {
    final db = await _db.database;
    final rows = await db.query(
      'msg_outbox',
      columns: ['recipient_device_id', 'state'],
      where: 'message_id = ?',
      whereArgs: [messageId.value],
    );
    return MessageDeliverySummary(
      rows
          .map((row) => DeviceDeliveryState(
                deviceId: DeviceId(row['recipient_device_id'] as String),
                state: DeliveryState.fromName(row['state'] as String?),
              ))
          .toList(),
    );
  }

  Future<List<OutboxRecord>> pendingForConversation(ConversationId id) async {
    final db = await _db.database;
    final rows = await db.query(
      'msg_outbox',
      where: 'conversation_id = ? AND state IN (?, ?)',
      whereArgs: [id.value, DeliveryState.queued.name, DeliveryState.sending.name],
      orderBy: 'enqueued_at_ms ASC',
    );
    return rows.map(OutboxRecord.fromRow).toList();
  }

  Future<int> countByState(DeliveryState state) async {
    final db = await _db.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM msg_outbox WHERE state = ?',
      [state.name],
    );
    return (result.first['c'] as int?) ?? 0;
  }

  /// Drops acknowledged rows once late receipts are no longer expected.
  Future<int> pruneAcked({Duration keepFor = const Duration(days: 1)}) async {
    final db = await _db.database;
    final cutoff = _clock() - keepFor.inMilliseconds;
    return db.delete(
      'msg_outbox',
      where: 'state IN (?, ?, ?) AND acked_at_ms IS NOT NULL AND acked_at_ms < ?',
      whereArgs: [
        DeliveryState.sent.name,
        DeliveryState.delivered.name,
        DeliveryState.read.name,
        cutoff,
      ],
    );
  }

  /// Fails rows that outlived [maxAge] instead of retrying forever.
  Future<void> _expireStale(int now) async {
    final db = await _db.database;
    await db.update(
      'msg_outbox',
      <String, Object?>{'state': DeliveryState.failed.name, 'last_error': 'EXPIRED'},
      where: 'state IN (?, ?) AND enqueued_at_ms < ?',
      whereArgs: [
        DeliveryState.queued.name,
        DeliveryState.sending.name,
        now - maxAge.inMilliseconds,
      ],
    );
  }

  /// Exponential backoff, capped. attempt 1 -> base, 2 -> 2x, 3 -> 4x…
  int _backoffMs(int attempt) {
    final exponent = math.min(attempt - 1, 16);
    final delay = baseBackoff.inMilliseconds * math.pow(2, exponent).toInt();
    return math.min(delay, maxBackoff.inMilliseconds);
  }
}
