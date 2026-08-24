/**
 * Redacted security logging for the realtime tier.
 *
 * Rule (docs/SOCKET_SECURITY.md §10, FASE 0.5 §17): logs must NEVER contain
 * private keys, plaintext, ciphertext, signatures, challenge bytes, session
 * ids, tokens or passwords. Identifiers are emitted as SHORT PREFIXES only
 * (data minimization) so operators can correlate without keeping a full
 * identifier trail.
 *
 * Everything a handler wants to log goes through `SecurityLog.event()`:
 *   * values of denied keys are dropped entirely (not even '[REDACTED]'
 *     placeholders carry data);
 *   * `*_id` fields are truncated to a 4-char prefix + ellipsis;
 *   * anything else must be a primitive (objects are dropped).
 *
 * A bounded ring buffer keeps the last N emitted lines so the E2E suite can
 * assert that no secret ever reaches a log line.
 */

export type LogSink = (line: string) => void;

/** Field names whose VALUE must never be logged, at any nesting level. */
export const FORBIDDEN_LOG_KEYS: ReadonlySet<string> = new Set([
  'signature',
  'challenge',
  'challenge_base64',
  'challenge_bytes',
  'session_id',
  'session',
  'token',
  'admin_token',
  'jwt',
  'apikey',
  'api_key',
  'authorization',
  'password',
  'passphrase',
  'pin',
  'ciphertext',
  'plaintext',
  'plain_text',
  'text',
  'content',
  'body',
  'message',
  'private_key',
  'privatekey',
  'public_key',
  'secret',
  'service_role',
  'service_role_key',
  'supabase_service_role_key',
]);

/** Keys logged as a short prefix instead of the full identifier. */
function isIdentifierKey(key: string): boolean {
  return key.endsWith('_id') || key === 'ip';
}

/** `abcd1234-...` -> `abcd…`. Never reversible into the full id. */
export function shortId(value: string): string {
  if (value.length === 0) return '—';
  if (value.length <= 4) return '…';
  return `${value.slice(0, 4)}…`;
}

function defaultSink(): LogSink {
  if (process.env.NOVA_REALTIME_LOG === 'off') return () => {};
  return (line: string) => process.stdout.write(`${line}\n`);
}

export class SecurityLog {
  private readonly sink: LogSink;
  private readonly buffer: string[] = [];
  private readonly bufferLimit: number;

  constructor(options: { sink?: LogSink; bufferLimit?: number } = {}) {
    this.sink = options.sink ?? defaultSink();
    this.bufferLimit = options.bufferLimit ?? 500;
  }

  /**
   * Emits one redacted structured line. `fields` values that are objects,
   * arrays or forbidden keys are dropped; identifiers are shortened.
   */
  event(name: string, fields: Record<string, unknown> = {}): void {
    const safe: Record<string, unknown> = { ev: name, t: Date.now() };
    for (const [key, value] of Object.entries(fields)) {
      const lower = key.toLowerCase();
      if (FORBIDDEN_LOG_KEYS.has(lower)) continue;
      if (value === undefined || value === null) continue;
      if (typeof value === 'object') continue; // never log structures
      if (typeof value === 'string' && isIdentifierKey(lower)) {
        safe[key] = shortId(value);
        continue;
      }
      if (typeof value === 'string' && value.length > 64) continue; // no blobs
      safe[key] = value;
    }
    const line = JSON.stringify(safe);
    this.buffer.push(line);
    if (this.buffer.length > this.bufferLimit) this.buffer.shift();
    this.sink(line);
  }

  /** Last emitted lines (tests / diagnostics). */
  lines(): string[] {
    return [...this.buffer];
  }

  clear(): void {
    this.buffer.length = 0;
  }
}
