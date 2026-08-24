/**
 * Supabase Directory — reads/writes the source of truth over PostgREST
 * with the SERVICE ROLE key. Only the realtime server holds this key
 * (never the client); RLS protects direct client access.
 *
 * Status (PASO 5): wired and type-checked, exercised only through the
 * Directory contract; the E2E suite runs against MemoryDirectory because
 * CI has no Supabase project. Required columns are documented in
 * server/sql/realtime_schema.sql. A 30s cache layer (docs §6) is PASO 6.
 */
import type { DeviceRecord } from '../protocol/device_registry.js';
import type { Directory } from './directory.js';
import type { DeviceStatus } from '../protocol/device_registry.js';

export class SupabaseDirectory implements Directory {
  constructor(
    private readonly supabaseUrl: string,
    private readonly serviceRoleKey: string,
  ) {
    if (!supabaseUrl || !serviceRoleKey) {
      throw new Error('SupabaseDirectory requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY');
    }
  }

  private async rest<T>(
    method: 'GET' | 'POST' | 'PATCH',
    table: string,
    query: string,
    body?: unknown,
  ): Promise<T[]> {
    const response = await fetch(
      `${this.supabaseUrl}/rest/v1/${table}${query}`,
      {
        method,
        headers: {
          apikey: this.serviceRoleKey,
          Authorization: `Bearer ${this.serviceRoleKey}`,
          'Content-Type': 'application/json',
          Prefer: method === 'POST' ? 'return=minimal' : 'return=representation',
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      },
    );
    if (!response.ok) {
      throw new Error(`supabase ${table} ${method} failed: ${response.status}`);
    }
    if (method === 'POST') return [];
    return (await response.json()) as T[];
  }

  async getDevice(deviceId: string): Promise<DeviceRecord | null> {
    const rows = await this.rest<{
      account_id: string;
      device_id: string;
      nova_id: string;
      public_key: string; // base64 raw Ed25519
      status: string;
    }>(
      'GET',
      'devices',
      `?device_id=eq.${encodeURIComponent(deviceId)}&select=account_id,device_id,nova_id,public_key,status&limit=1`,
    );
    const row = rows[0];
    if (!row) return null;
    return {
      accountId: row.account_id,
      deviceId: row.device_id,
      novaId: row.nova_id,
      ed25519PublicKey: Uint8Array.from(Buffer.from(row.public_key, 'base64')),
      status: this.normalizeStatus(row.status),
    };
  }

  private normalizeStatus(raw: string): DeviceStatus {
    if (raw === 'active' || raw === 'revoked' || raw === 'pending') return raw;
    return 'pending';
  }

  async upsertDevice(record: DeviceRecord): Promise<void> {
    await this.rest('POST', 'devices', '?on_conflict=device_id', {
      account_id: record.accountId,
      device_id: record.deviceId,
      nova_id: record.novaId,
      public_key: Buffer.from(record.ed25519PublicKey).toString('base64'),
      status: record.status,
    });
  }

  async revokeDevice(deviceId: string): Promise<boolean> {
    await this.rest(
      'PATCH',
      'devices',
      `?device_id=eq.${encodeURIComponent(deviceId)}`,
      { status: 'revoked' },
    );
    return true;
  }

  async isConversationMember(conversationId: string, accountId: string): Promise<boolean> {
    const rows = await this.rest<{ conversation_id: string }>(
      'GET',
      'conversation_members',
      `?conversation_id=eq.${encodeURIComponent(conversationId)}&account_id=eq.${encodeURIComponent(accountId)}&select=conversation_id&limit=1`,
    );
    return rows.length > 0;
  }

  async addConversationMember(conversationId: string, accountId: string): Promise<void> {
    await this.rest('POST', 'conversation_members', '?on_conflict=conversation_id,account_id', {
      conversation_id: conversationId,
      account_id: accountId,
    });
  }

  async listConversationsForAccount(accountId: string): Promise<string[]> {
    const rows = await this.rest<{ conversation_id: string }>(
      'GET',
      'conversation_members',
      `?account_id=eq.${encodeURIComponent(accountId)}&select=conversation_id`,
    );
    return rows.map((row) => row.conversation_id);
  }

  async hasRelationship(a: string, b: string): Promise<boolean> {
    const rows = await this.rest<{ peer: string }>(
      'GET',
      'contacts',
      `?account_id=eq.${encodeURIComponent(a)}&peer_id=eq.${encodeURIComponent(b)}&blocked=eq.false&select=peer_id&limit=1`,
    );
    return rows.length > 0;
  }

  async addRelationship(a: string, b: string): Promise<void> {
    await this.rest('POST', 'contacts', '?on_conflict=account_id,peer_id', [
      { account_id: a, peer_id: b, blocked: false },
      { account_id: b, peer_id: a, blocked: false },
    ]);
  }

  async presenceAudience(subjectAccountId: string): Promise<string[]> {
    const rows = await this.rest<{ viewer_id: string }>(
      'GET',
      'presence_audience',
      `?subject_id=eq.${encodeURIComponent(subjectAccountId)}&select=viewer_id`,
    );
    return rows.map((row) => row.viewer_id);
  }

  async allowPresence(subjectAccountId: string, viewerAccountId: string): Promise<void> {
    await this.rest('POST', 'presence_audience', '?on_conflict=subject_id,viewer_id', {
      subject_id: subjectAccountId,
      viewer_id: viewerAccountId,
    });
  }
}
