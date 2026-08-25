/// Persistent per-conversation sync cursors (§14).
///
/// §14: "Nunca saltar directamente al head sin procesar páginas
/// pendientes." The cursor therefore advances ONLY after a page has been
/// applied and persisted — never to the server's head on faith.
///
/// TWO distinct sequences are tracked, matching the server model:
///
///   log_seq     ordering of the EVENT LOG — the sync cursor. Receipts on
///               an old message get a NEW log_seq, so they are still
///               replayed to a client already past that message.
///   server_seq  ordering of MESSAGES within a conversation. Used for gap
///               detection, not for sync pagination.
///
/// Conflating the two was a real FASE 0.5 bug: receipts became
/// unrecoverable after a reconnect. They stay separate here.
library;

import 'package:sqflite/sqflite.dart';

import '../model/message_ids.dart';
import 'messaging_database.dart';

class SyncCursor {
  const SyncCursor({
    required this.conversationId,
    required this.lastLogSeq,
    required this.lastServerSeq,
    this.updatedAtMs = 0,
  });

  final ConversationId conversationId;
  final int lastLogSeq;
  final int lastServerSeq;
  final int updatedAtMs;
}

class SyncCursorStore {
  SyncCursorStore(this._db, {int Function()? clock})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final MessagingDatabase _db;
  final int Function() _clock;

  Future<SyncCursor> cursorFor(ConversationId conversationId) async {
    final db = await _db.database;
    final rows = await db.query(
      'msg_sync_cursor',
      where: 'conversation_id = ?',
      whereArgs: [conversationId.value],
      limit: 1,
    );
    if (rows.isEmpty) {
      return SyncCursor(conversationId: conversationId, lastLogSeq: 0, lastServerSeq: 0);
    }
    final row = rows.first;
    return SyncCursor(
      conversationId: conversationId,
      lastLogSeq: (row['last_log_seq'] as int?) ?? 0,
      lastServerSeq: (row['last_server_seq'] as int?) ?? 0,
      updatedAtMs: (row['updated_at_ms'] as int?) ?? 0,
    );
  }

  /// All known cursors, as the map the server expects for an
  /// account-wide `sync.request` (`{cursors: {conv: last_seq}}`).
  Future<Map<String, int>> allCursors() async {
    final db = await _db.database;
    final rows = await db.query('msg_sync_cursor');
    return <String, int>{
      for (final row in rows)
        row['conversation_id'] as String: (row['last_log_seq'] as int?) ?? 0,
    };
  }

  /// Advances the cursor. MONOTONIC by construction: a late or replayed
  /// response carrying a lower value can never rewind it, which would
  /// otherwise cause an infinite re-sync loop.
  Future<void> advance(
    ConversationId conversationId, {
    int? logSeq,
    int? serverSeq,
  }) async {
    final current = await cursorFor(conversationId);
    final nextLog = (logSeq != null && logSeq > current.lastLogSeq)
        ? logSeq
        : current.lastLogSeq;
    final nextServer = (serverSeq != null && serverSeq > current.lastServerSeq)
        ? serverSeq
        : current.lastServerSeq;
    if (nextLog == current.lastLogSeq && nextServer == current.lastServerSeq) {
      return;
    }
    final db = await _db.database;
    await db.insert(
      'msg_sync_cursor',
      <String, Object?>{
        'conversation_id': conversationId.value,
        'last_log_seq': nextLog,
        'last_server_seq': nextServer,
        'updated_at_ms': _clock(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Resets a cursor to force a full replay.
  ///
  /// Recovery path for a corrupted cursor (§14): re-reading everything is
  /// safe because the Inbox deduplicates by message_id.
  Future<void> reset(ConversationId conversationId) async {
    final db = await _db.database;
    await db.delete(
      'msg_sync_cursor',
      where: 'conversation_id = ?',
      whereArgs: [conversationId.value],
    );
  }
}
