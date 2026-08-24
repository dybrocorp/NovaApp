/**
 * Bootstrap: config from env, store backend, HTTP + Socket.IO + admin API,
 * graceful shutdown (system.shutdown broadcast before closing).
 *
 * Run: node dist/index.js (see README.md / docker-compose.yml).
 */
import { configFromEnv } from './config.js';
import { RealtimeServer } from './realtime_server.js';
import { attachAdminApi } from './admin_api.js';
import { MemoryDirectory } from './directory/memory_directory.js';
import { SupabaseDirectory } from './directory/supabase_directory.js';
import { MemoryRealtimeStore } from './store/realtime_store.js';

async function main(): Promise<void> {
  const config = configFromEnv();
  const directory =
    config.storeBackend === 'supabase'
      ? new SupabaseDirectory(config.supabaseUrl, config.supabaseServiceRoleKey)
      : new MemoryDirectory();

  const server = new RealtimeServer({ config, directory, store: new MemoryRealtimeStore() });
  attachAdminApi(server);

  const port = Number.parseInt(process.env.PORT ?? '4000', 10);
  const boundPort = await server.start({ port, host: '0.0.0.0' });

  // Redacted startup log (docs/SOCKET_SECURITY.md §10): no secrets.
  console.log(
    JSON.stringify({
      msg: 'novaapp-realtime-server up',
      port: boundPort,
      socket_path: config.socketPath,
      transports: ['websocket'],
      store: config.storeBackend,
      challenge_ttl_ms: config.challengeTtlMs,
      session_ttl_ms: config.sessionTtlMs,
      admin_api: config.adminToken ? 'token-protected' : 'open (set ADMIN_TOKEN in prod)',
    }),
  );

  const shutdown = (signal: string) => {
    console.log(JSON.stringify({ msg: 'shutdown', signal }));
    void server.stop().then(() => process.exit(0));
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

void main();
