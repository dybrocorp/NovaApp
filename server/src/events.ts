/**
 * Typed, namespaced Socket.IO event catalog for NovaApp.
 *
 * 1:1 port of `lib/core/socket/socket_events.dart` (PASO 4). The event
 * names are wire contract with the Flutter client — do not rename.
 *
 * Domains: auth, presence, message, sync, call, device, system.
 */

export const SocketEvent = {
  // ===== AUTH =====
  authChallenge: 'auth.challenge',
  authResponse: 'auth.response',
  authSuccess: 'auth.success',
  authFailure: 'auth.failure',

  // ===== MESSAGING =====
  messageSend: 'message.send',
  messageNew: 'message.new',
  messageAck: 'message.ack',
  messageDelivered: 'message.delivered',
  messageRead: 'message.read',
  messageTyping: 'message.typing',
  // FASE 1 §21/§22 — delete-for-everyone tombstone + expiry purge.
  messageDelete: 'message.delete',
  messageDeleted: 'message.deleted',
  messageExpired: 'message.expired',

  // ===== SYNC =====
  syncRequest: 'sync.request',
  syncResponse: 'sync.response',

  // ===== PRESENCE =====
  presenceUpdate: 'presence.update',
  presenceChanged: 'presence.changed',

  // ===== CALL SIGNALING (WebRTC signaling ONLY — no media) =====
  callOffer: 'call.offer',
  callAnswer: 'call.answer',
  callIce: 'call.ice',
  callEnd: 'call.end',

  // ===== DEVICE =====
  deviceAdded: 'device.added',
  deviceRevoked: 'device.revoked',

  // ===== SYSTEM =====
  systemError: 'system.error',
  systemShutdown: 'system.shutdown',
} as const;

export type SocketEventName =
  (typeof SocketEvent)[keyof typeof SocketEvent];

export enum SocketEventDomain {
  auth = 'auth',
  presence = 'presence',
  message = 'message',
  sync = 'sync',
  call = 'call',
  device = 'device',
  system = 'system',
}

/** Maps a wire event name to its domain, or null if unknown. */
export function domainForEvent(event: string): SocketEventDomain | null {
  if (event.startsWith('auth.')) return SocketEventDomain.auth;
  if (event.startsWith('message.')) return SocketEventDomain.message;
  if (event.startsWith('sync.')) return SocketEventDomain.sync;
  if (event.startsWith('presence.')) return SocketEventDomain.presence;
  if (event.startsWith('call.')) return SocketEventDomain.call;
  if (event.startsWith('device.')) return SocketEventDomain.device;
  if (event.startsWith('system.')) return SocketEventDomain.system;
  return null;
}

/** Events a client is allowed to EMIT. Server enforces the same list. */
export const CLIENT_EMITTABLE_EVENTS: ReadonlySet<string> = new Set<string>([
  SocketEvent.authResponse,
  SocketEvent.messageSend,
  SocketEvent.messageTyping,
  SocketEvent.messageRead,
  SocketEvent.messageDelivered,
  SocketEvent.messageDelete,
  SocketEvent.syncRequest,
  SocketEvent.presenceUpdate,
  SocketEvent.callOffer,
  SocketEvent.callAnswer,
  SocketEvent.callIce,
  SocketEvent.callEnd,
]);

export function isClientEmittableEvent(event: string): boolean {
  return CLIENT_EMITTABLE_EVENTS.has(event);
}
