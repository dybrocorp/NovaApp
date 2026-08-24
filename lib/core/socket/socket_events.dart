/// Typed, namespaced Socket.IO event catalog for NovaApp.
///
/// Events are grouped by domain. A socket handler must NEVER be registered
/// for a raw string that is not declared here.
///
/// Naming convention: `<domain>.<name>` (dot-namespaced).
///
/// Domains:
///   auth   — cryptographic challenge-response handshake
///   presence — online/offline/last_seen (privacy-restricted)
///   message  — E2EE ciphertext transport + delivery states
///   sync     — catch-up after reconnection / network switch
///   call     — WebRTC SIGNALLING ONLY (never audio/video media)
///   device   — multi-device lifecycle (added / revoked)
///   system   — server shutdown / generic errors
library;

/// Socket.IO event names used by NovaApp.
///
/// All names are lowercase, dot-namespaced and stable: they are part of the
/// wire contract with the realtime server (see docs/SOCKET_SERVER_ARCHITECTURE.md).
abstract final class SocketEvent {
  // ===== AUTH =====
  /// Server -> Client. Payload: AuthChallenge (auth/challenge payloads).
  static const String authChallenge = 'auth.challenge';

  /// Client -> Server. Payload: AuthResponsePayload.
  static const String authResponse = 'auth.response';

  /// Server -> Client. Payload: AuthSuccess.
  static const String authSuccess = 'auth.success';

  /// Server -> Client. Payload: AuthFailure (generic code, see SocketErrorCode).
  static const String authFailure = 'auth.failure';

  // ===== MESSAGING =====
  /// Client -> Server. Payload: MessageEnvelope (ciphertext ONLY).
  static const String messageSend = 'message.send';

  /// Server -> Client. Fan-out of a new E2EE message (with server_seq).
  static const String messageNew = 'message.new';

  /// Server -> Client. ACK: server RECEIVED and persisted the envelope.
  /// This does NOT mean delivered or read.
  static const String messageAck = 'message.ack';

  /// Server -> Client. Recipient's device acknowledged receipt.
  static const String messageDelivered = 'message.delivered';

  /// Server -> Client. Recipient read the conversation.
  static const String messageRead = 'message.read';

  /// Both directions. Typing indicator (rate limited).
  static const String messageTyping = 'message.typing';

  // ===== SYNC =====
  /// Client -> Server. Request events missed since `last_cursor`.
  static const String syncRequest = 'sync.request';

  /// Server -> Client. Missed events batch + new cursor.
  static const String syncResponse = 'sync.response';

  // ===== PRESENCE =====
  /// Client -> Server. Own presence update (server fans out only to
  /// relationships allowed by privacy settings).
  static const String presenceUpdate = 'presence.update';

  /// Server -> Client. Presence of an authorized subscribed user.
  static const String presenceChanged = 'presence.changed';

  // ===== CALL SIGNALING (WebRTC signaling ONLY — no media) =====
  static const String callOffer = 'call.offer';
  static const String callAnswer = 'call.answer';
  static const String callIce = 'call.ice';
  static const String callEnd = 'call.end';

  // ===== DEVICE =====
  /// Server -> Client. A new device was approved for this account.
  static const String deviceAdded = 'device.added';

  /// Server -> Client. THIS device (or a sibling) was revoked.
  /// Receiving it for the local device id means: disconnect, session
  /// invalidated, reconnection permanently blocked.
  static const String deviceRevoked = 'device.revoked';

  // ===== SYSTEM =====
  /// Server -> Client. Generic error with a SocketErrorCode.
  static const String systemError = 'system.error';

  /// Server -> Client. Server is going down; clients should back off.
  static const String systemShutdown = 'system.shutdown';
}

/// Domains used for authorization and rate-limit bucketing.
enum SocketEventDomain { auth, presence, message, sync, call, device, system }

/// Maps a wire event name to its domain, or null if unknown.
SocketEventDomain? domainForEvent(String event) {
  if (event.startsWith('auth.')) return SocketEventDomain.auth;
  if (event.startsWith('message.')) return SocketEventDomain.message;
  if (event.startsWith('sync.')) return SocketEventDomain.sync;
  if (event.startsWith('presence.')) return SocketEventDomain.presence;
  if (event.startsWith('call.')) return SocketEventDomain.call;
  if (event.startsWith('device.')) return SocketEventDomain.device;
  if (event.startsWith('system.')) return SocketEventDomain.system;
  return null;
}

/// Returns true only for events a client is allowed to EMIT.
///
/// Everything else is server -> client. The server enforces the same list;
/// this exists so the client cannot even attempt to emit server-only events.
bool isClientEmittableEvent(String event) {
  return const <String>{
    SocketEvent.authResponse,
    SocketEvent.messageSend,
    SocketEvent.messageTyping,
    SocketEvent.messageRead,
    SocketEvent.messageDelivered,
    SocketEvent.syncRequest,
    SocketEvent.presenceUpdate,
    SocketEvent.callOffer,
    SocketEvent.callAnswer,
    SocketEvent.callIce,
    SocketEvent.callEnd,
  }.contains(event);
}
