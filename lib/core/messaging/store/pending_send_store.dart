/// FASE 1 (port from `arena/01a04505-novaapp` @e15325c) — durable
/// PRE-ENCRYPTION pending-send queue (§12 "no connection → store, no loss").
///
/// main already covers "transport dropped but a session exists": envelopes
/// are encrypted, persisted to the Outbox and retried (§11 — persist before
/// transmit). The uncovered cold case: first contact while offline (no
/// X3DH bundle reachable, `sessionForSending` -> null) previously failed
/// the send outright (`NO_SESSION`) — user content was accepted nowhere and
/// lost from the user's point of view.
///
/// This store fixes exactly that: the composed body is durably kept
/// device-local (same trust domain as the ratchet-state storage: plaintext
/// here is no more exposed than the in-memory view the UI already holds),
/// keyed by the LOGICAL message id — so a re-queue can never duplicate and
/// a later flush can never drop. Encryption order == enqueue order
/// (created_at + rowid), which keeps per-device sending chains sane.
library;

import 'package:sqflite/sqflite.dart';

import '../model/message_body.dart';
import '../model/message_ids.dart';
import 'messaging_database.dart';

class PendingSend {
  const PendingSend({
    required this.messageId,
    required this.conversationId,
    required this.selfAccountId,
    required this.peerAccountId,
    required this.bodyJson,
    required this.createdAtMs,
    this.expiresAtMs,
  });

  final MessageId messageId;
  final ConversationId conversationId;
  final AccountId selfAccountId;
  final AccountId peerAccountId;
  final String bodyJson;
  final int createdAtMs;
  final int? expiresAtMs;

  Map<String, Object?> toRow() => <String, Object?>{
        'message_id': messageId.value,
        'conversation_id': conversationId.value,
        'self_account_id': selfAccountId.value,
        'peer_account_id': peerAccountId.value,
        'body_json': bodyJson,
        'created_at_ms': createdAtMs,
        'expires_at_ms': expiresAtMs,
      };

  static PendingSend? fromRow(Map<String, Object?> row) {
    final id = row['message_id'];
    final conv = row['conversation_id'];
    final self = row['self_account_id'];
    final peer = row['peer_account_id'];
    final body = row['body_json'];
    final created = row['created_at_ms'];
    if (id is! String || conv is! String || self is! String ||
        peer is! String || body is! String || created is! int) {
      return null; // malformed row: skipped, never applied blindly
    }
    final expires = row['expires_at_ms'];
    return PendingSend(
      messageId: MessageId(id),
      conversationId: ConversationId(conv),
      selfAccountId: AccountId(self),
      peerAccountId: AccountId(peer),
      bodyJson: body,
      createdAtMs: created,
      expiresAtMs: expires is int ? expires : null,
    );
  }
}

class PendingSendStore {
  PendingSendStore(this._db);

  final MessagingDatabase _db;

  /// Idempotent by logical message id (PRIMARY KEY + ignore): queueing the
  /// same send twice leaves exactly one row.
  Future<void> enqueue({
    required MessageId messageId,
    required ConversationId conversationId,
    required AccountId selfAccountId,
    required AccountId peerAccountId,
    required MessageBody body,
    int? expiresAtMs,
    int? nowMs,
  }) async {
    final db = await _db.database;
    await db.insert(
      'msg_pending_send',
      PendingSend(
        messageId: messageId,
        conversationId: conversationId,
        selfAccountId: selfAccountId,
        peerAccountId: peerAccountId,
        bodyJson: body.encode(),
        createdAtMs:
            nowMs ?? DateTime.now().millisecondsSinceEpoch,
        expiresAtMs: expiresAtMs,
      ).toRow(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Oldest-first (created_at + rowid tie-break: millisecond ties must not
  /// reorder a user's queue).
  Future<List<PendingSend>> due({int limit = 50}) async {
    final db = await _db.database;
    final rows =
        await db.query('msg_pending_send', orderBy: 'created_at_ms, rowid', limit: limit);
    return rows.map(PendingSend.fromRow).whereType<PendingSend>().toList(growable: false);
  }

  Future<void> remove(MessageId messageId) async {
    final db = await _db.database;
    await db.delete('msg_pending_send',
        where: 'message_id = ?', whereArgs: [messageId.value]);
  }

  Future<int> count() async {
    final db = await _db.database;
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM msg_pending_send');
    return (rows.first['c'] as int?) ?? 0;
  }

  /// Rows whose send TTL elapsed before they could ever be encrypted:
  /// erased (content was never accepted onto the network — a pending send
  /// older than its own expiry must not resurface later).
  Future<int> purgeExpired(int nowMs) async {
    final db = await _db.database;
    return db.delete('msg_pending_send',
        where: 'expires_at_ms IS NOT NULL AND expires_at_ms <= ?',
        whereArgs: [nowMs]);
  }
}
