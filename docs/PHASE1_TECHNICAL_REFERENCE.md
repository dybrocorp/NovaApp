# FASE 1 — Technical Reference (ported files)

File-level map of the 2026-08-28 port (D1–D5). The rest of the engine is documented in
`PHASE1_MESSAGE_ARCHITECTURE.md` (§1–§20) as it exists on `main`.

---

## 12. Ported files (2026-08-28, option (A))

Client (new):
* `lib/core/messaging/store/pending_send_store.dart` — `PendingSendStore` / `PendingSend`:
  durable pre-encryption queue (`msg_pending_send`, idempotent by logical id via
  `ConflictAlgorithm.ignore`, FIFO `created_at_ms, rowid`, hard `expires_at`).
* `lib/core/messaging/crypto/ratchet_state_persistence.dart` — additive codec over the
  frozen `RatchetState.toJson` carrying the missing X25519 seed (`my_ratchet_private`).
Client (modified):
* `messaging_database.dart` — schema v? adds `msg_pending_send` (index on
  `(created_at_ms, rowid)`).
* `message_send_service.dart` — optional `pendingSends` ctor param; `SendResult.
  queuedOffline` + `SendResult.skippedDevices`; `flushPending()`.
* `message_receive_service.dart` — `onTombstone(payload)` entry for
  `message.deleted` / `message.expired` (the app layer routes these events; the client
  has no generic dispatcher yet); ack/delivered/read/expired handlers run before the
  `_isRedacted` barrier.
* `inbox_store.dart` — `redact(messageId)`.
* `pubspec.yaml` — dev-dependency `sqflite_common_ffi` (Dart tests run on host).

Server (modified): `events.ts` (+`message.delete`, `message.deleted`, `message.expired`
types), `realtime_store.ts` / `supabase_store.ts` (`redactMessages` + `purgeExpired`
contract), `realtime_server.ts` (command wiring, sweep with unref'd timer cleared in
`stop()`), `config.ts` (`messagePurgeIntervalMs`, default 5000).
`supabase/novaapp_schema.sql` — partial index `idx_rtm_undelivered_expiring`.
