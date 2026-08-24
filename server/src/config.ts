/**
 * Server configuration — every value maps to docs/SOCKET_SERVER_ARCHITECTURE.md
 * §10 (deployment) and docs/SOCKET_SECURITY.md §8 (rate limits).
 *
 * Values mirror the audited client configuration
 * (`lib/core/socket/socket_config.dart`) so both ends enforce the same
 * transport policy: WebSocket-only, no silent polling downgrade.
 */

export interface RealtimeServerConfig {
  /** engine.io / socket.io path. Default '/socket.io/'. */
  socketPath: string;
  pingIntervalMs: number;
  pingTimeoutMs: number;
  /** engine.io maxHttpBufferSize (bytes). Default 1e6. */
  maxHttpBufferSize: number;
  /** Max base64 chars for an E2EE envelope ciphertext (~64 KiB decoded). */
  maxCiphertextBase64Chars: number;
  /** CORS origin allowlist (web client; the mobile app does not use CORS). */
  corsOrigins: string[];
  /** Bearer token for /admin/* endpoints. Empty = admin open (local/tests). */
  adminToken: string;

  // ===== Handshake =====
  challengeTtlMs: number;
  maxAuthAttemptsPerConnection: number;
  authFailuresLockout: number;
  authLockoutMs: number;
  /** Lockout scopes: 'device', 'ip' (both by default, per docs §2). */
  authLockoutScopes: ('device' | 'ip')[];

  // ===== Sessions =====
  sessionTtlMs: number;

  // ===== Rate limits (per socket; token bucket, burst = rate) =====
  authPerMinute: number;
  messagePerMinute: number;
  typingPerMinute: number;
  signalingPerMinute: number;
  syncPerMinute: number;
  presencePerMinute: number;
  totalEventsPerMinute: number;
  /** New connections per IP per minute (io.use middleware). */
  newConnectionsPerIpPerMinute: number;

  // ===== Sync =====
  syncPageLimit: number;

  // ===== Stores =====
  /** 'memory' (single node, default) | 'supabase' (Postgres via PostgREST). */
  storeBackend: 'memory' | 'supabase';
  supabaseUrl: string;
  supabaseServiceRoleKey: string;
}

function intFromEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function csvFromEnv(name: string): string[] | null {
  const raw = process.env[name];
  if (!raw || raw.trim() === '*') return null; // null = allow all
  return raw
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

export function configFromEnv(env: NodeJS.ProcessEnv = process.env): RealtimeServerConfig {
  const lockoutScopesRaw = env.AUTH_LOCKOUT_SCOPES ?? 'device,ip';
  const scopes = lockoutScopesRaw
    .split(',')
    .map((s) => s.trim())
    .filter((s): s is 'device' | 'ip' => s === 'device' || s === 'ip');
  return {
    socketPath: env.SOCKET_PATH ?? '/socket.io/',
    pingIntervalMs: intFromEnv('PING_INTERVAL', 25_000),
    pingTimeoutMs: intFromEnv('PING_TIMEOUT', 20_000),
    maxHttpBufferSize: intFromEnv('MAX_HTTP_BUFFER_SIZE', 1_000_000),
    maxCiphertextBase64Chars: intFromEnv(
      'MAX_CIPHERTEXT_BASE64_CHARS',
      87_384, // ceil(64 KiB * 4/3)
    ),
    corsOrigins: csvFromEnv('CORS_ORIGIN') ?? ['*'],
    adminToken: env.ADMIN_TOKEN ?? '',

    challengeTtlMs: intFromEnv('CHALLENGE_TTL_MS', 60_000),
    maxAuthAttemptsPerConnection: intFromEnv('MAX_AUTH_ATTEMPTS_PER_CONNECTION', 3),
    authFailuresLockout: intFromEnv('AUTH_FAILURES_LOCKOUT', 5),
    authLockoutMs: intFromEnv('AUTH_LOCKOUT_MS', 120_000),
    authLockoutScopes: scopes.length > 0 ? scopes : ['device', 'ip'],

    sessionTtlMs: intFromEnv('SESSION_TTL_MS', 24 * 60 * 60 * 1000),

    // Same values as SocketRateLimitPresets (client) — the server applies
    // its own limits; equal by design so honest clients never trip them.
    authPerMinute: intFromEnv('AUTH_PER_MINUTE', 5),
    messagePerMinute: intFromEnv('MESSAGE_PER_MINUTE', 30),
    typingPerMinute: intFromEnv('TYPING_PER_MINUTE', 12),
    signalingPerMinute: intFromEnv('SIGNALING_PER_MINUTE', 60),
    syncPerMinute: intFromEnv('SYNC_PER_MINUTE', 6),
    presencePerMinute: intFromEnv('PRESENCE_PER_MINUTE', 12),
    totalEventsPerMinute: intFromEnv('TOTAL_EVENTS_PER_MINUTE', 120),
    newConnectionsPerIpPerMinute: intFromEnv('NEW_CONNECTIONS_PER_IP_PER_MINUTE', 60),

    syncPageLimit: intFromEnv('SYNC_PAGE_LIMIT', 100),

    storeBackend: env.STORE_BACKEND === 'supabase' ? 'supabase' : 'memory',
    supabaseUrl: env.SUPABASE_URL ?? '',
    supabaseServiceRoleKey: env.SUPABASE_SERVICE_ROLE_KEY ?? '',
  };
}

export const DEFAULT_CONFIG: RealtimeServerConfig = configFromEnv({});
