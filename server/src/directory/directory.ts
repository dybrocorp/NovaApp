/**
 * Directory — the server's view of the source of truth (Supabase in
 * production): devices + identity keys, conversation memberships,
 * relationships (contacts / blocked), presence audiences.
 *
 * The realtime server NEVER trusts client claims about any of these; it
 * asks the Directory on every authorization decision (with a short-lived
 * cache where the backend is remote — see docs/SOCKET_SERVER_ARCHITECTURE.md §6).
 */
import type { DeviceRecord } from '../protocol/device_registry.js';

export interface Directory {
  /** Registered identity record for a device (public key + status). */
  getDevice(deviceId: string): Promise<DeviceRecord | null>;
  upsertDevice(record: DeviceRecord): Promise<void>;
  /** Marks a device revoked; false if unknown. */
  revokeDevice(deviceId: string): Promise<boolean>;

  /** Conversation membership (account ids). Server-side truth only. */
  isConversationMember(conversationId: string, accountId: string): Promise<boolean>;
  addConversationMember(conversationId: string, accountId: string): Promise<void>;
  listConversationsForAccount(accountId: string): Promise<string[]>;

  /** Contact relationship (mutual, neither blocked). Gates call.* relay. */
  hasRelationship(a: string, b: string): Promise<boolean>;
  addRelationship(a: string, b: string): Promise<void>;

  /** Accounts allowed to see `subjectAccountId`'s presence (privacy). */
  presenceAudience(subjectAccountId: string): Promise<string[]>;
  allowPresence(subjectAccountId: string, viewerAccountId: string): Promise<void>;
}
