/**
 * HTTP management surface of the realtime server.
 *
 *   GET  /healthz                     — liveness + readiness
 *   POST /admin/devices               — register device identity (bootstrap)
 *   POST /admin/devices/revoke        — revoke device (fan-out + kill sessions)
 *   POST /admin/sessions/revoke       — remote logout of one socket
 *   POST /admin/conversations         — seed membership (server-side truth)
 *   POST /admin/relationships         — seed contact relationship
 *   POST /admin/presence-audience     — seed presence privacy audience
 *
 * In production these endpoints are the local equivalent of the Supabase
 * webhook path (docs/SOCKET_SERVER_ARCHITECTURE.md §9: revocación
 * reactiva) and REQUIRE a Bearer ADMIN_TOKEN. Without a token configured
 * (local dev / tests) they are open on loopback.
 */
import type { IncomingMessage, ServerResponse } from 'node:http';
import type { RealtimeServer } from './realtime_server.js';

export function attachAdminApi(server: RealtimeServer): void {
  server.httpServerInstance.on('request', handler);

  async function handler(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? '/', 'http://localhost');
    try {
      if (req.method === 'GET' && url.pathname === '/healthz') {
        respond(res, 200, {
          status: 'ok',
          uptime_s: server.uptimeSeconds,
          sockets: server.connectedSockets,
          sessions: server.sessions.liveCount,
          challenges: server.challenges.liveCount,
          store: server.config.storeBackend,
        });
        return;
      }
      if (url.pathname === '/healthz') {
        respond(res, 405, { error: 'method_not_allowed' });
        return;
      }
      if (!url.pathname.startsWith('/admin/')) {
        respond(res, 404, { error: 'not_found' });
        return;
      }
      if (req.method !== 'POST') {
        respond(res, 405, { error: 'method_not_allowed' });
        return;
      }
      const token = server.config.adminToken;
      if (token) {
        const auth = req.headers.authorization ?? '';
        if (auth !== `Bearer ${token}`) {
          respond(res, 401, { error: 'unauthorized' });
          return;
        }
      }

      const body = await readJsonBody(req);
      switch (url.pathname) {
        case '/admin/devices': {
          requireFields(body, ['account_id', 'device_id', 'nova_id', 'public_key_base64']);
          await server.adminRegisterDevice({
            accountId: String(body['account_id']),
            deviceId: String(body['device_id']),
            novaId: String(body['nova_id']),
            publicKeyBase64: String(body['public_key_base64']),
          });
          respond(res, 201, { ok: true });
          return;
        }
        case '/admin/devices/revoke': {
          requireFields(body, ['device_id']);
          const result = await server.adminRevokeDevice(String(body['device_id']));
          respond(res, 200, { ok: true, ...result });
          return;
        }
        case '/admin/sessions/revoke': {
          requireFields(body, ['session_id']);
          const ok = server.adminRevokeSession(String(body['session_id']));
          respond(res, ok ? 200 : 404, { ok });
          return;
        }
        case '/admin/conversations': {
          requireFields(body, ['conversation_id', 'members']);
          const members = body['members'];
          if (!Array.isArray(members)) throw badRequest('members must be an array');
          for (const member of members) {
            await server.adminAddConversationMember(String(body['conversation_id']), String(member));
          }
          respond(res, 201, { ok: true });
          return;
        }
        case '/admin/relationships': {
          requireFields(body, ['account_a', 'account_b']);
          await server.adminAddRelationship(
            String(body['account_a']),
            String(body['account_b']),
          );
          respond(res, 201, { ok: true });
          return;
        }
        case '/admin/presence-audience': {
          requireFields(body, ['subject', 'viewer']);
          await server.adminAllowPresence(String(body['subject']), String(body['viewer']));
          respond(res, 201, { ok: true });
          return;
        }
        default:
          respond(res, 404, { error: 'not_found' });
      }
    } catch (error) {
      const status = (error as { status?: number }).status ?? 500;
      const message =
        status === 400 && error instanceof Error ? error.message : 'internal_error';
      respond(res, status, { error: message });
    }
  }
}

function badRequest(message: string): Error & { status: number } {
  const error = new Error(message) as Error & { status: number };
  error.status = 400;
  return error;
}

function requireFields(body: Record<string, unknown>, fields: string[]): void {
  for (const field of fields) {
    const value = body[field];
    if (value === undefined || value === null || String(value).length === 0) {
      throw badRequest(`missing field: ${field}`);
    }
  }
}

function readJsonBody(req: IncomingMessage): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on('data', (chunk: Buffer) => {
      size += chunk.length;
      if (size > 1_000_000) {
        reject(badRequest('body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (chunks.length === 0) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        reject(badRequest('invalid json'));
      }
    });
    req.on('error', () => reject(badRequest('read error')));
  });
}

function respond(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(payload),
  });
  res.end(payload);
}
