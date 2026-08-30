# FASE 1 — Message Protocol (tombstone & expiry delta)

Baseline protocol: the `message.send / message.new / sync` flow and envelopes are defined by
`server/src/events.ts` + `lib/core/messaging/model/message_envelope_v1.dart` (FASE 1 engine on
`main`). This document records only the ported wire-level additions from 2026-08-28.

---

## 10. Tombstone & expiry wire events (ported 2026-08-28)

* `message.deleted` (broadcast to every room member, including the requester):
  `{conversation_id, message_id, deleted_at (ms), deleted_reason: "sender_deleted"}`
* `message.expired` (emitted by the expiry sweep when a sent row passes its
  `expires_at`): `{conversation_id, message_id, deleted_at, deleted_reason: "expired"}`
* On redaction the server REWRITES stored `message.new` payloads in the event log to
  `{..., ciphertext: null, deleted: true, deleted_reason}` — sync replay yields the
  tombstone, never the resurrected ciphertext. `ciphertext` is set to `''` in storage
  (Supabase column is NOT NULL); media references are cleared.
* A `message.delete` command from a NON-sender member returns generic
  `forbidden {code: "FORBIDDEN"}` (no existence leak); the sender gets
  `deleted` / `already_tombstoned` hints in the ack.
* Clients receiving either event MUST delete the local Inbox entry for that logical id.
