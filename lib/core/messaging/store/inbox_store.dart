/// Persistent Inbox (§13).
///
/// §13 mandates the exact ordering:
///
///   socket event -> validate -> PERSIST LOCALLY -> ACK/DELIVERED
///                -> decrypt -> update state
///
/// Persisting BEFORE acknowledging is the whole point. If the app dies
/// between receiving and processing, the message is already on disk and
/// is picked up on restart. Acknowledging first would let the server drop
/// a message the client never actually stored.
///
/// ## Deduplication
///
/// `message_id` is the PRIMARY KEY and inserts use `ignore`. The same
/// message can therefore arrive live AND again through a sync replay
/// (§14) and still be applied exactly once — the second insert is a
/// no-op, which is reported back to the caller so it can skip processing.
library;

import 'package:sqflite/sqflite.dart';

import '../model/message_envelope_v1.dart';
import '../model/message_ids.dart';
import '../model/message_type.dart';
import 'messaging_database.dart';

/// Outcome of accepting an inbound envelope.
enum InboxAcceptResult {
  /// Stored for the first time — the caller should process it.
  stored,

  /// Already known (live delivery + sync replay). Do NOT process again.
  duplicate,

  /// Rejected before storage (malformed / failed validation).
  rejected,
}

class InboxRecord {
  const InboxRecord({
    required this.envelope,
    required this.receivedAtMs,
    required this.processed,
    required this.deliveredSent,
    required this.decryptFailed,
  });

  final MessageEnvelopeV1 envelope;
  final int receivedAtMs;
  final bool processed;
  final bool deliveredSent;
  final bool decryptFailed;

  static InboxRecord fromRow(Map<String, Object?> row) => InboxRecord(
        envelope: MessageEnvelopeV1(
          messageId: MessageId(row['message_id'] as String),
          conversationId: ConversationId(row['conversation_id'] as String),
          senderAccountId: AccountId(row['sender_account_id'] as String),
          senderDeviceId: DeviceId(row['sender_device_id'] as String),
          recipientDeviceId: DeviceId(row['recipient_device_id'] as String),
          messageType:
              MessageType.fromWireTag(row['message_type'] as String?) ?? MessageType.system,
          ciphertextBase64: row['ciphertext'] as String,
          ciphertextHeaderType: row['header_type'] as String,
          envelopeVersion: (row['envelope_version'] as int?) ?? kEnvelopeVersionV1,
          clientTimestampMs: row['client_ts_ms'] as int?,
          serverSeq: row['server_seq'] as int?,
          logSeq: row['log_seq'] as int?,
          expiresAtMs: row['expires_at_ms'] as int?,
        ),
        receivedAtMs: (row['received_at_ms'] as int?) ?? 0,
        processed: ((row['processed'] as int?) ?? 0) == 1,
        deliveredSent: ((row['delivered_sent'] as int?) ?? 0) == 1,
        decryptFailed: ((row['decrypt_failed'] as int?) ?? 0) == 1,
      );
}

class InboxStore {
  InboxStore(this._db, {int Function()? clock})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final MessagingDatabase _db;
  final int Function() _clock;

  /// Persists an inbound envelope before any processing (§13).
  ///
  /// Returns [InboxAcceptResult.duplicate] when the message was already
  /// stored, so the caller skips decryption and state updates entirely.
  Future<InboxAcceptResult> accept(MessageEnvelopeV1 envelope) async {
    if (!envelope.messageId.isValid ||
        !envelope.conversationId.isValid ||
        envelope.ciphertextBase64.isEmpty) {
      return InboxAcceptResult.rejected;
    }

    final db = await _db.database;
    final rowId = await db.insert(
      'msg_inbox',
      <String, Object?>{
        'message_id': envelope.messageId.value,
        'conversation_id': envelope.conversationId.value,
        'sender_account_id': envelope.senderAccountId.value,
        'sender_device_id': envelope.senderDeviceId.value,
        'recipient_device_id': envelope.recipientDeviceId.value,
        'message_type': envelope.messageType.wireTag,
        'envelope_version': envelope.envelopeVersion,
        'ciphertext': envelope.ciphertextBase64,
        'header_type': envelope.ciphertextHeaderType,
        'server_seq': envelope.serverSeq,
        'log_seq': envelope.logSeq,
        'client_ts_ms': envelope.clientTimestampMs,
        'expires_at_ms': envelope.expiresAtMs,
        'received_at_ms': _clock(),
        'processed': 0,
        'delivered_sent': 0,
        'decrypt_failed': 0,
      },
      // Dedup: the PK rejects a second copy silently.
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return rowId == 0 ? InboxAcceptResult.duplicate : InboxAcceptResult.stored;
  }

  Future<bool> contains(MessageId messageId) async {
    final db = await _db.database;
    final rows = await db.query(
      'msg_inbox',
      columns: ['message_id'],
      where: 'message_id = ?',
      whereArgs: [messageId.value],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Envelopes stored but not yet fully processed. Drives crash recovery:
  /// on restart these are decrypted and applied.
  Future<List<InboxRecord>> pendingProcessing({int limit = 100}) async {
    final db = await _db.database;
    final rows = await db.query(
      'msg_inbox',
      where: 'processed = 0 AND decrypt_failed = 0',
      orderBy: 'server_seq ASC, received_at_ms ASC',
      limit: limit,
    );
    return rows.map(InboxRecord.fromRow).toList();
  }

  /// Stored messages whose DELIVERED receipt has not been emitted yet.
  Future<List<InboxRecord>> pendingDeliveryReceipts({int limit = 100}) async {
    final db = await _db.database;
    final rows = await db.query(
      'msg_inbox',
      where: 'delivered_sent = 0',
      orderBy: 'received_at_ms ASC',
      limit: limit,
    );
    return rows.map(InboxRecord.fromRow).toList();
  }

  Future<void> markProcessed(MessageId messageId) async {
    final db = await _db.database;
    await db.update(
      'msg_inbox',
      <String, Object?>{'processed': 1},
      where: 'message_id = ?',
      whereArgs: [messageId.value],
    );
  }

  Future<void> markDeliveredSent(MessageId messageId) async {
    final db = await _db.database;
    await db.update(
      'msg_inbox',
      <String, Object?>{'delivered_sent': 1},
      where: 'message_id = ?',
      whereArgs: [messageId.value],
    );
  }

  /// Flags a message whose ciphertext could not be authenticated.
  ///
  /// Kept, not deleted: re-inserting the same id must stay a duplicate,
  /// otherwise an attacker could retry a tampered ciphertext forever.
  Future<void> markDecryptFailed(MessageId messageId) async {
    final db = await _db.database;
    await db.update(
      'msg_inbox',
      <String, Object?>{'decrypt_failed': 1, 'processed': 1},
      where: 'message_id = ?',
      whereArgs: [messageId.value],
    );
  }

  Future<List<InboxRecord>> forConversation(
    ConversationId conversationId, {
    int limit = 100,
    int offset = 0,
  }) async {
    final db = await _db.database;
    final rows = await db.query(
      'msg_inbox',
      where: 'conversation_id = ?',
      whereArgs: [conversationId.value],
      orderBy: 'server_seq ASC',
      limit: limit,
      offset: offset,
    );
    return rows.map(InboxRecord.fromRow).toList();
  }

  /// Highest contiguous server_seq applied for a conversation.
  ///
  /// Stops at the first hole rather than reporting the maximum: with
  /// 1,2,3,7 the answer is 3, so gap detection (§14) can request the
  /// missing range instead of silently skipping it.
  Future<int> lastContiguousSeq(ConversationId conversationId) async {
    final db = await _db.database;
    final rows = await db.query(
      'msg_inbox',
      columns: ['server_seq'],
      where: 'conversation_id = ? AND server_seq IS NOT NULL',
      whereArgs: [conversationId.value],
      orderBy: 'server_seq ASC',
    );
    var contiguous = 0;
    for (final row in rows) {
      final seq = row['server_seq'] as int?;
      if (seq == null) continue;
      if (seq == contiguous + 1) {
        contiguous = seq;
      } else if (seq > contiguous + 1) {
        break; // hole found
      }
    }
    return contiguous;
  }

  /// Removes expired disappearing messages (§22).
  /// FASE 1 §21 (port): erase the envelope row(s) of a logically deleted
  /// message (delete-for-everyone / expiry consumed on-device). The server
  /// has already destroyed the ciphertext; the decrypted plaintext is
  /// memory-only BY DESIGN on this architecture (see file header), so
  /// deleting the envelope here IS the full local erase.
  Future<int> redact(MessageId messageId) async {
    final db = await _db.database;
    return db.delete('msg_inbox',
        where: 'message_id = ?', whereArgs: [messageId.value]);
  }

  Future<int> purgeExpired() async {
    final db = await _db.database;
    return db.delete(
      'msg_inbox',
      where: 'expires_at_ms IS NOT NULL AND expires_at_ms < ?',
      whereArgs: [_clock()],
    );
  }

  Future<int> count() async {
    final db = await _db.database;
    final result = await db.rawQuery('SELECT COUNT(*) AS c FROM msg_inbox');
    return (result.first['c'] as int?) ?? 0;
  }
}
