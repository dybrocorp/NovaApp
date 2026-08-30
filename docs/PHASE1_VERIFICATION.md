# FASE 1 — Verification (port delta)

Verification for the pre-existing FASE 1 suites on `main` stands as recorded in
`PHASE1_COMPLETION_REPORT.md`. This file records evidence for the 2026-08-28 port only.

---

## 11. Port delta verification (2026-08-28)

Executed in the sandbox (server):
* `server/test/e2e_phase1_delete_expiry.test.ts` — 5/5 new: sender-only delete fan-out +
  non-sender generic forbidden; tombstone beats sync-resurrection (event-log rewrite);
  fake-clock expiry purge → `message.expired` broadcast + replayed tombstone carries
  `deleted_reason: "expired"`; idempotent/idle sweeps; non-member forbidden.
* Full `cd server && npm test` with the port applied: **129/129** (every pre-existing
  suite byte-identical in behavior) + the 5 new = green; `npm run typecheck` clean.

NOT RUN — Flutter SDK unavailable in this environment:
* `test/messaging/port_gaps_test.dart` (D1/D2/D3 guards: pending-store idempotence/FIFO/
  TTL purge, cold-offline queue → reconnect flush exactly-once, partial fan-out
  `skippedDevices`, legacy-serializer loss documented + codec round-trip with chain
  continuation). Run with `flutter test` on a workstation; uses `sqflite_common_ffi`.
* Existing 75 `test/messaging/*` suites — unchanged by the port except additive fields.

NOT RUN — Supabase environment unavailable: schema `idx_rtm_undelivered_expiring`
partial index and `ciphertext` redaction against a real Postgres.
