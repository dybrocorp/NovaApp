/// Local SQLite schema for the messaging engine (§12, §13, §34).
///
/// Separate database file from the legacy `nova_app.db`: the engine must
/// not inherit the legacy schema (which stores PLAINTEXT in `messages`)
/// and must be able to evolve without migrating it (§42).
///
/// ## What is stored here
///
///   outbox   ciphertext envelopes awaiting acknowledgement
///   inbox    received envelopes, persisted BEFORE processing
///   delivery per-device delivery state (§17)
///   cursors  per-conversation sync cursor (log_seq)
///
/// ## What is NOT stored here (§34)
///
///   * private keys        -> flutter_secure_storage (Keychain/Keystore)
///   * ratchet state       -> flutter_secure_storage
///   * decrypted plaintext -> kept in memory for the UI only
///
/// Both queues hold ciphertext plus routing metadata. An attacker who
/// reads this file learns WHO talked to WHOM and WHEN (metadata), but not
/// WHAT was said. Persisting decrypted text would need SQLCipher and is
/// documented as pending in docs/PHASE1_MESSAGE_ARCHITECTURE.md §7 —
/// it is not silently done here.
library;

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// Engine database name. Distinct from the legacy `nova_app.db`.
const String kMessagingDatabaseName = 'nova_messaging.db';
const int kMessagingSchemaVersion = 1;

class MessagingDatabase {
  MessagingDatabase({Database? database, String? databaseName})
      : _injected = database,
        _databaseName = databaseName ?? kMessagingDatabaseName;

  final Database? _injected;
  final String _databaseName;
  Database? _database;

  Future<Database> get database async {
    if (_injected != null) {
      await _ensureSchema(_injected);
      return _injected;
    }
    if (_database != null) return _database!;
    final path = join(await getDatabasesPath(), _databaseName);
    _database = await openDatabase(
      path,
      version: kMessagingSchemaVersion,
      onCreate: (db, _) => _createSchema(db),
      onConfigure: (db) async {
        // Cascades on delivery rows depend on real FK enforcement.
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
    return _database!;
  }

  static Future<void> _ensureSchema(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='msg_outbox'",
    );
    if (tables.isEmpty) await _createSchema(db);
  }

  static Future<void> createSchemaForTest(Database db) => _createSchema(db);

  static Future<void> _createSchema(Database db) async {
    // ---- Outbox (§12) -------------------------------------------------
    // One row per (message, target device): the fan-out is per device
    // (§15), and each copy is acknowledged independently.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS msg_outbox (
        message_id          TEXT NOT NULL,
        recipient_device_id TEXT NOT NULL,
        conversation_id     TEXT NOT NULL,
        sender_account_id   TEXT NOT NULL,
        sender_device_id    TEXT NOT NULL,
        message_type        TEXT NOT NULL,
        envelope_version    INTEGER NOT NULL DEFAULT 1,
        ciphertext          TEXT NOT NULL,
        header_type         TEXT NOT NULL,
        client_ts_ms        INTEGER,
        expires_at_ms       INTEGER,
        state               TEXT NOT NULL DEFAULT 'queued',
        attempts            INTEGER NOT NULL DEFAULT 0,
        next_attempt_at_ms  INTEGER NOT NULL DEFAULT 0,
        last_error          TEXT,
        enqueued_at_ms      INTEGER NOT NULL,
        acked_at_ms         INTEGER,
        server_seq          INTEGER,
        PRIMARY KEY (message_id, recipient_device_id)
      )
    ''');
    // Drives the "what should I send now" query.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_outbox_due ON msg_outbox(state, next_attempt_at_ms)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_outbox_conversation ON msg_outbox(conversation_id)',
    );

    // ---- Inbox (§13) --------------------------------------------------
    // PRIMARY KEY on message_id is the deduplication guarantee: a message
    // redelivered live and again through sync can only be inserted once.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS msg_inbox (
        message_id        TEXT PRIMARY KEY,
        conversation_id   TEXT NOT NULL,
        sender_account_id TEXT NOT NULL,
        sender_device_id  TEXT NOT NULL,
        recipient_device_id TEXT NOT NULL,
        message_type      TEXT NOT NULL,
        envelope_version  INTEGER NOT NULL DEFAULT 1,
        ciphertext        TEXT NOT NULL,
        header_type       TEXT NOT NULL,
        server_seq        INTEGER,
        log_seq           INTEGER,
        client_ts_ms      INTEGER,
        expires_at_ms     INTEGER,
        received_at_ms    INTEGER NOT NULL,
        processed         INTEGER NOT NULL DEFAULT 0,
        delivered_sent    INTEGER NOT NULL DEFAULT 0,
        decrypt_failed    INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_inbox_conversation ON msg_inbox(conversation_id, server_seq)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_inbox_unprocessed ON msg_inbox(processed)',
    );

    // ---- Per-device delivery state (§17) ------------------------------
    await db.execute('''
      CREATE TABLE IF NOT EXISTS msg_delivery (
        message_id    TEXT NOT NULL,
        device_id     TEXT NOT NULL,
        state         TEXT NOT NULL,
        updated_at_ms INTEGER NOT NULL,
        PRIMARY KEY (message_id, device_id)
      )
    ''');

    // ---- Sync cursors (§14) -------------------------------------------
    // log_seq is the event-log cursor (distinct from server_seq, the
    // message order) — see FASE 0.5 RealtimeStore.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS msg_sync_cursor (
        conversation_id  TEXT PRIMARY KEY,
        last_log_seq     INTEGER NOT NULL DEFAULT 0,
        last_server_seq  INTEGER NOT NULL DEFAULT 0,
        updated_at_ms    INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // ---- Conversations -------------------------------------------------
    await db.execute('''
      CREATE TABLE IF NOT EXISTS msg_conversation (
        conversation_id TEXT PRIMARY KEY,
        peer_account_id TEXT,
        created_at_ms   INTEGER NOT NULL,
        last_activity_ms INTEGER,
        disappearing_ttl_s INTEGER
      )
    ''');

    // ---- Pending sends (FASE 1 port §12) ------------------------------
    // PRE-encryption durable queue for cold-offline sends (no session /
    // no topology yet). Keyed by the LOGICAL message id => re-queue is a
    // no-op, flush is exactly-once. Device-local, like all msg_* tables.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS msg_pending_send (
        message_id      TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        self_account_id TEXT NOT NULL,
        peer_account_id TEXT NOT NULL,
        body_json       TEXT NOT NULL,
        created_at_ms   INTEGER NOT NULL,
        expires_at_ms   INTEGER
      )
    ''');
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
