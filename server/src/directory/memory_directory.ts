/**
 * In-memory Directory — default backend for a single node and for the
 * E2E suite. Mirrors the reference model from
 * `lib/core/socket/protocol/authorization_policy.dart` (PASO 4).
 */
import type { DeviceRecord } from '../protocol/device_registry.js';
import type { Directory } from './directory.js';

export class MemoryDirectory implements Directory {
  private readonly devices = new Map<string, DeviceRecord>();
  private readonly conversationMembers = new Map<string, Set<string>>();
  private readonly accountConversations = new Map<string, Set<string>>();
  private readonly relationships = new Map<string, Set<string>>();
  private readonly presenceAudiences = new Map<string, Set<string>>();

  async getDevice(deviceId: string): Promise<DeviceRecord | null> {
    return this.devices.get(deviceId) ?? null;
  }

  async upsertDevice(record: DeviceRecord): Promise<void> {
    this.devices.set(record.deviceId, { ...record });
  }

  async revokeDevice(deviceId: string): Promise<boolean> {
    const record = this.devices.get(deviceId);
    if (!record) return false;
    this.devices.set(deviceId, { ...record, status: 'revoked' });
    return true;
  }

  async isConversationMember(conversationId: string, accountId: string): Promise<boolean> {
    return this.conversationMembers.get(conversationId)?.has(accountId) ?? false;
  }

  async addConversationMember(conversationId: string, accountId: string): Promise<void> {
    if (!this.conversationMembers.has(conversationId)) {
      this.conversationMembers.set(conversationId, new Set());
    }
    this.conversationMembers.get(conversationId)!.add(accountId);
    if (!this.accountConversations.has(accountId)) {
      this.accountConversations.set(accountId, new Set());
    }
    this.accountConversations.get(accountId)!.add(conversationId);
  }

  async listConversationsForAccount(accountId: string): Promise<string[]> {
    return [...(this.accountConversations.get(accountId) ?? [])];
  }

  async hasRelationship(a: string, b: string): Promise<boolean> {
    return this.relationships.get(a)?.has(b) ?? false;
  }

  async addRelationship(a: string, b: string): Promise<void> {
    if (!this.relationships.has(a)) this.relationships.set(a, new Set());
    if (!this.relationships.has(b)) this.relationships.set(b, new Set());
    this.relationships.get(a)!.add(b);
    this.relationships.get(b)!.add(a);
  }

  async presenceAudience(subjectAccountId: string): Promise<string[]> {
    return [...(this.presenceAudiences.get(subjectAccountId) ?? [])];
  }

  async allowPresence(subjectAccountId: string, viewerAccountId: string): Promise<void> {
    if (!this.presenceAudiences.has(subjectAccountId)) {
      this.presenceAudiences.set(subjectAccountId, new Set());
    }
    this.presenceAudiences.get(subjectAccountId)!.add(viewerAccountId);
  }
}
