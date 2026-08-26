/**
 * SupabaseRealtimeStore — the realtime tier's hot state persisted in
 * Supabase (Postgres) over PostgREST with the SERVICE ROLE key.
 *
 * This is the SUPABASE leg of the FASE 0.5 topology:
 *
 *   CLIENT A -> WSS -> REALTIME SERVER -> SUPABASE
 *                                      <- SUPABASE
 *            <- WSS <- REALTIME SERVER
 *
 * Hard rules:
 *   * only OPAQUE ciphertext + server metadata is written (server_seq,
 *     received_at_ms). The server cannot decrypt anything it stores;
 *   * the service role key lives ONLY here (backend). It is never sent to
 *     a client, never logged, never echoed in an error;
 *   * `nextSeq` MUST be atomic. PostgREST cannot express "INCR" safely, so
 *     it is delegated to the Postgres function `nova_next_seq` (see
 *     server/sql/realtime_schema.sql). If that RPC is missing the store
 *     FAILS CLOSED instead of silently racing two writers onto one seq.
 *
 * Tablas requeridas: supabase/novaapp_schema.sql (prefijo `realtime_`).
 */
import type {
  AppendableEvent,
  PresenceRecord,
  RealtimeStore,
  StoredEvent,
  StoredMessage,
} from './realtime_store.js';

interface MessageRow {
  message_id: string;
  conversation_id: string;
  sender_account_id: string;
  sender_device_id: string;
  ciphertext: string;
  header_type: string;
  server_seq: number;
  received_at_ms: number;
  client_ts_ms: number | null;
}

interface EventRow {
  conversation_id: string;
  type: string;
  server_seq: number;
  log_seq: number;
  at_ms: number;
  payload: Record<string, unknown>;
}

interface PresenceRow {
  account_id: string;
  status: string;
  last_seen_ms: number;
}

export class SupabaseRealtimeStore implements RealtimeStore {
  constructor(
    private readonly supabaseUrl: string,
    private readonly serviceRoleKey: string,
  ) {
    if (!supabaseUrl || !serviceRoleKey) {
      throw new Error(
        'SupabaseRealtimeStore requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY',
      );
    }
  }

  private headers(prefer: string): Record<string, string> {
    return {
      apikey: this.serviceRoleKey,
      Authorization: `Bearer ${this.serviceRoleKey}`,
      'Content-Type': 'application/json',
      Prefer: prefer,
    };
  }

  /**
   * PostgREST call. Errors NEVER include the response body: a Postgres
   * error can echo row data, and rows here contain ciphertext.
   */
  private async rest<T>(
    method: 'GET' | 'POST' | 'PATCH',
    path: string,
    body?: unknown,
    prefer = 'return=minimal',
  ): Promise<T[]> {
    const response = await fetch(`${this.supabaseUrl}/rest/v1/${path}`, {
      method,
      headers: this.headers(prefer),
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (!response.ok) {
      throw new Error(`supabase store ${method} failed: ${response.status}`);
    }
    const text = await response.text();
    if (text.length === 0) return [];
    return JSON.parse(text) as T[];
  }

  /**
   * Atomic counter RPC. Fail closed: without an atomic counter two nodes
   * could mint the same cursor value, silently corrupting ordering + sync.
   */
  private async rpcCounter(fn: string, conversationId: string): Promise<number> {
    const response = await fetch(`${this.supabaseUrl}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: this.headers('return=representation'),
      body: JSON.stringify({ p_conversation_id: conversationId }),
    });
    if (!response.ok) {
      throw new Error(
        `supabase ${fn} rpc failed: ${response.status} ` +
          '(apply server/sql/realtime_schema.sql)',
      );
    }
    const value = await response.json();
    const seq = typeof value === 'number' ? value : Number((value as { seq?: number })?.seq);
    if (!Number.isFinite(seq) || seq <= 0) {
      throw new Error(`supabase ${fn} returned an invalid sequence`);
    }
    return seq;
  }

  /** Atomic per-conversation MESSAGE sequence via the `nova_next_seq` RPC. */
  async nextSeq(conversationId: string): Promise<number> {
    return this.rpcCounter('nova_next_seq', conversationId);
  }

  async latestSeq(conversationId: string): Promise<number> {
    const rows = await this.rest<{ last_seq: number }>(
      'GET',
      `realtime_cursors?conversation_id=eq.${encodeURIComponent(conversationId)}` +
        '&select=last_seq&limit=1',
      undefined,
      'return=representation',
    );
    return rows[0]?.last_seq ?? 0;
  }

  async persistMessage(message: StoredMessage): Promise<void> {
    await this.rest('POST', 'realtime_messages?on_conflict=message_id', {
      message_id: message.messageId,
      conversation_id: message.conversationId,
      sender_account_id: message.senderAccountId,
      sender_device_id: message.senderDeviceId,
      ciphertext: message.ciphertextBase64,
      header_type: message.headerType,
      server_seq: message.serverSeq,
      received_at_ms: message.receivedAtMs,
      client_ts_ms: message.clientTimestampMs ?? null,
    });
  }

  async findMessage(messageId: string): Promise<StoredMessage | null> {
    const rows = await this.rest<MessageRow>(
      'GET',
      `realtime_messages?message_id=eq.${encodeURIComponent(messageId)}&select=*&limit=1`,
      undefined,
      'return=representation',
    );
    const row = rows[0];
    if (!row) return null;
    return {
      messageId: row.message_id,
      conversationId: row.conversation_id,
      senderAccountId: row.sender_account_id,
      senderDeviceId: row.sender_device_id,
      ciphertextBase64: row.ciphertext,
      headerType: row.header_type,
      serverSeq: Number(row.server_seq),
      receivedAtMs: Number(row.received_at_ms),
      clientTimestampMs: row.client_ts_ms === null ? undefined : Number(row.client_ts_ms),
    };
  }

  /**
   * Appends to the event log. `log_seq` is assigned atomically by the
   * `nova_next_log_seq` RPC — the same fail-closed rule as nextSeq: two
   * nodes must never mint the same cursor value.
   */
  async appendEvent(event: AppendableEvent): Promise<number> {
    const logSeq = await this.rpcCounter('nova_next_log_seq', event.conversationId);
    await this.rest('POST', 'realtime_events', {
      conversation_id: event.conversationId,
      type: event.type,
      server_seq: event.serverSeq,
      log_seq: logSeq,
      at_ms: event.atMs,
      payload: event.payload,
    });
    return logSeq;
  }

  async eventsSince(
    conversationId: string,
    lastLogSeq: number,
    limit: number,
  ): Promise<StoredEvent[]> {
    const rows = await this.rest<EventRow>(
      'GET',
      `realtime_events?conversation_id=eq.${encodeURIComponent(conversationId)}` +
        `&log_seq=gt.${lastLogSeq}&select=*&order=log_seq.asc&limit=${limit}`,
      undefined,
      'return=representation',
    );
    return rows.map((row) => ({
      conversationId: row.conversation_id,
      type: row.type as StoredEvent['type'],
      serverSeq: Number(row.server_seq),
      logSeq: Number(row.log_seq),
      atMs: Number(row.at_ms),
      payload: (row.payload ?? {}) as Record<string, unknown>,
    }));
  }

  async latestLogSeq(conversationId: string): Promise<number> {
    const rows = await this.rest<{ last_log_seq: number }>(
      'GET',
      `realtime_cursors?conversation_id=eq.${encodeURIComponent(conversationId)}` +
        '&select=last_log_seq&limit=1',
      undefined,
      'return=representation',
    );
    return rows[0]?.last_log_seq ?? 0;
  }

  async getPresence(accountId: string): Promise<PresenceRecord | null> {
    const rows = await this.rest<PresenceRow>(
      'GET',
      `realtime_presence?account_id=eq.${encodeURIComponent(accountId)}&select=*&limit=1`,
      undefined,
      'return=representation',
    );
    const row = rows[0];
    if (!row) return null;
    return {
      accountId: row.account_id,
      status: row.status === 'online' ? 'online' : 'offline',
      lastSeenMs: Number(row.last_seen_ms),
    };
  }

  async setPresence(record: PresenceRecord): Promise<void> {
    await this.rest('POST', 'realtime_presence?on_conflict=account_id', {
      account_id: record.accountId,
      status: record.status,
      last_seen_ms: record.lastSeenMs,
    });
  }
}
