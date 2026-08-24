import 'dart:async';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

import 'package:novaapp/core/socket/auth/auth_payloads.dart';
import 'package:novaapp/core/socket/auth/auth_signer.dart';
import 'package:novaapp/core/socket/auth/socket_session.dart';
import 'package:novaapp/core/socket/heartbeat_watchdog.dart';
import 'package:novaapp/core/socket/messaging/ack_state.dart';
import 'package:novaapp/core/socket/messaging/gap_detector.dart';
import 'package:novaapp/core/socket/messaging/message_envelope.dart';
import 'package:novaapp/core/socket/messaging/outbox.dart';
import 'package:novaapp/core/socket/network_transition_handler.dart';
import 'package:novaapp/core/socket/rate_limiter.dart';
import 'package:novaapp/core/socket/reconnect_policy.dart';
import 'package:novaapp/core/socket/socket_config.dart';
import 'package:novaapp/core/socket/socket_events.dart';
import 'package:novaapp/core/socket/socket_log.dart';

import 'connectivity_service.dart';
import 'logger_service.dart';

/// Connection lifecycle states.
enum SocketConnectionStatus {
  /// No connection and not trying (initial or after user disconnect).
  disconnected,

  /// Socket handshake in progress.
  connecting,

  /// Connected, waiting for the server challenge.
  awaitingChallenge,

  /// Challenge received, signed response sent, awaiting verdict.
  authenticating,

  /// Authenticated session active — the only state where events flow.
  authenticated,

  /// Disconnected, scheduled automatic reconnection with backoff.
  reconnecting,

  /// Automatic reconnection exhausted — waits for connectivity change or
  /// an explicit reconnect() call. Never loops forever.
  failed,

  /// Device revoked or permanently rejected. Reconnection is refused until
  /// the app re-registers the device. Terminal state.
  blocked,
}

/// Hardened Socket.IO transport for NovaApp.
///
/// Architecture:
///   NovaApp -> Socket.IO (events + session mgmt) -> WebSocket transport
///           -> Realtime server -> Supabase/backend
///
/// Security-critical behavior is delegated to small audited modules:
///   * handshake:   AuthSigner (+ ChallengeStore/HandshakeEngine protocol
///                  reference used by tests and the server spec)
///   * sessions:    SocketSession (single-use per connection, expiry)
///   * reconnect:   ReconnectPolicy (exponential backoff + full jitter,
///                  bounded attempts)
///   * networks:    NetworkTransitionHandler (wifi<->mobile, outage -> resync)
///   * liveness:    HeartbeatWatchdog (detects dead connections, no extra
///                  packets — engine.io ping/pong does the heartbeat)
///   * idempotency: OutboxQueue + stable message ids + server dedup by id
///   * limits:      SocketRateLimiters (token buckets per event domain)
///
/// Invariants enforced here:
///   1. No event is emitted or accepted before `auth.success`.
///   2. Identity (account/device/nova) is never re-sent per event; the
///      session bound to the socket carries it server-side.
///   3. A reconnect ALWAYS re-runs the full handshake (new challenge, new
///      signature, new session) — old sessions are never reused.
///   4. Only ciphertext envelopes travel as messages.
///   5. Logs are redacted (SocketLog): no signatures, keys, tokens,
///      challenges, ciphertext or plaintext ever reach the log.
class WebSocketService {
  /// Public constructor. [serverUrl] overrides SOCKET_SERVER_URL from .env;
  /// [config] overrides all transport options (see SocketConfig docs).
  factory WebSocketService({
    String? serverUrl,
    SocketConfig? config,
    DateTime Function()? clock,
  }) {
    final resolved = config ??
        SocketConfig(
          serverUrl: serverUrl ?? dotenv.env['SOCKET_SERVER_URL'] ?? '',
          // Debug builds may fall back to polling and ws:// for local
          // development ONLY. Release builds: websocket + wss, always.
          transports:
              kDebugMode ? const ['websocket', 'polling'] : const ['websocket'],
          allowInsecureTransport: kDebugMode,
        );
    final effective =
        (serverUrl != null && config != null) ? config.withServerUrl(serverUrl) : resolved;
    final now = clock ?? DateTime.now;
    return WebSocketService._(config: effective, clock: now);
  }

  WebSocketService._({
    required SocketConfig config,
    required DateTime Function() clock,
  })  : _config = config,
        _clock = clock,
        _heartbeatWatchdog = HeartbeatWatchdog(
          silenceThreshold: config.silenceThreshold,
          clock: clock,
        ),
        _rateLimiters = SocketRateLimiters(clock: clock),
        _outbox = OutboxQueue(clock: clock);

  final SocketConfig _config;
  final DateTime Function() _clock;

  IO.Socket? _socket;
  Timer? _reconnectTimer;
  Timer? _authTimeoutTimer;
  Timer? _heartbeatTimer;
  int _connectionGeneration = 0;

  final ReconnectPolicy _reconnectPolicy = ReconnectPolicy();
  final HeartbeatWatchdog _heartbeatWatchdog;
  final NetworkTransitionHandler _networkHandler = NetworkTransitionHandler();
  final SocketRateLimiters _rateLimiters;
  final OutboxQueue _outbox;
  final SequenceGapDetector _gapDetector = SequenceGapDetector();
  final AuthSigner _signer = const AuthSigner();

  StreamSubscription<ConnectivityState>? _connectivitySub;

  // Identity of THIS device (set at connect()).
  String? _accountId;
  String? _deviceId;
  String? _novaId;
  SimpleKeyPair? _identityKeyPair;

  SocketSession _session = SocketSession.none;
  SocketConnectionStatus _status = SocketConnectionStatus.disconnected;
  int _authAttemptsThisConnection = 0;
  int _consecutiveAuthFailures = 0;
  DateTime? _authLockoutUntil;
  bool _userInitiatedDisconnect = false;
  int _lastSyncCursor = 0;

  final Map<String, Function(dynamic)> _messageHandlers = {};
  final Map<String, Function()> _eventHandlers = {};

  final StreamController<Map<String, dynamic>> _messageStreamController =
      StreamController.broadcast();
  final StreamController<bool> _connectionStatusController =
      StreamController.broadcast();
  final StreamController<bool> _authStatusController =
      StreamController.broadcast();
  final StreamController<SocketConnectionStatus> _statusController =
      StreamController.broadcast();

  // ==================== PUBLIC API ====================

  /// Stream of inbound (ciphertext) message payloads — authenticated only.
  Stream<Map<String, dynamic>> get messageStream =>
      _messageStreamController.stream;

  Stream<bool> get connectionStatusStream =>
      _connectionStatusController.stream;

  Stream<bool> get authStatusStream => _authStatusController.stream;

  /// Fine-grained lifecycle stream (see [SocketConnectionStatus]).
  Stream<SocketConnectionStatus> get statusStream => _statusController.stream;

  bool get isConnected => _socket?.connected ?? false;

  bool get isAuthenticated =>
      _status == SocketConnectionStatus.authenticated &&
      _session.isUsable(now: _clock());

  SocketConnectionStatus get status => _status;

  /// Current session (opaque id; never sent back to the server by us).
  SocketSession get session => _session;

  /// Opens a connection and runs the cryptographic handshake.
  ///
  /// [userId] is the Nova ID. [accountId], [deviceId] and [identityKeyPair]
  /// are REQUIRED to prove device-bound identity: the client fails closed
  /// (no connection attempt) when they are missing, because the server
  /// would reject the handshake anyway.
  Future<void> connect(
    String userId, {
    SimpleKeyPair? identityKeyPair,
    String? accountId,
    String? deviceId,
  }) async {
    _novaId = userId;
    _identityKeyPair = identityKeyPair;
    _accountId = accountId;
    _deviceId = deviceId;

    if (_status == SocketConnectionStatus.blocked) {
      LoggerService.warning(
        'Connect refused: device is blocked (revoked)',
        tag: 'Socket',
      );
      return;
    }
    if (isConnected ||
        _status == SocketConnectionStatus.connecting ||
        _status == SocketConnectionStatus.awaitingChallenge ||
        _status == SocketConnectionStatus.authenticating) {
      return;
    }
    if (accountId == null ||
        accountId.isEmpty ||
        deviceId == null ||
        deviceId.isEmpty ||
        identityKeyPair == null) {
      LoggerService.warning(
        'Connect refused: account/device identity or key missing (fail closed)',
        tag: 'Socket',
      );
      _setStatus(SocketConnectionStatus.disconnected);
      return;
    }

    _userInitiatedDisconnect = false;
    _reconnectPolicy.reset();
    _openSocket();
  }

  /// Subscribes to connectivity changes to handle WiFi <-> mobile switches
  /// and outages (reconnect -> re-auth -> resync). Call once at app start.
  void bindConnectivity(ConnectivityService connectivity) {
    _connectivitySub?.cancel();
    _connectivitySub = connectivity.onConnectivityChanged.listen((state) {
      final online = state != ConnectivityState.offline;
      final kind = switch (state) {
        ConnectivityState.wifi => 'wifi',
        ConnectivityState.mobile => 'mobile',
        _ => 'other',
      };
      final decision = _networkHandler.onConnectivityChanged(
        online: online,
        networkKind: kind,
        socketConnected: isConnected,
      );
      switch (decision) {
        case ConnectivityDecision.none:
          break;
        case ConnectivityDecision.reconnectNow:
          _networkHandler.markResyncNeeded();
          _scheduleReconnect(immediate: true);
        case ConnectivityDecision.forceDisconnectAndReconnect:
          _networkHandler.markResyncNeeded();
          _recycleConnection('network changed', immediate: true);
      }
    });
  }

  /// Sends an E2EE ciphertext envelope (the ONLY accepted message format).
  ///
  /// Idempotent: a stable message_id is attached at creation; retries after
  /// reconnection reuse the same id so the server can deduplicate.
  void sendMessageEnvelope(MessageEnvelope envelope) {
    final invalidReason = MessageEnvelope.validateOutgoing(envelope);
    if (invalidReason != null) {
      LoggerService.warning('Envelope rejected: $invalidReason', tag: 'Socket');
      return;
    }
    final entry = _outbox.enqueue(envelope);
    if (entry.status != MessageDeliveryStatus.queued) {
      // Already sent/acked — duplicate send suppressed.
      return;
    }
    _flushOutbox();
  }

  /// Legacy convenience wrapper. [message] must be an E2EE payload map with
  /// `ciphertext` (+ optional header/conversation fields). Plaintext-looking
  /// maps are rejected locally — the server must never receive unencrypted
  /// message content.
  void sendMessage(String recipientId, Map<String, dynamic> message) {
    if (containsPlaintextPayload(message)) {
      LoggerService.warning(
        'Send refused: payload contains plaintext fields',
        tag: 'Socket',
      );
      return;
    }
    final ciphertext = message['ciphertext'] as String?;
    if (ciphertext == null || ciphertext.isEmpty) {
      LoggerService.warning('Send refused: no ciphertext', tag: 'Socket');
      return;
    }
    final envelope = MessageEnvelope.create(
      conversationId:
          message['conversation_id'] as String? ?? 'dm:$recipientId',
      senderDeviceId: _deviceId ?? '',
      ciphertextBase64: ciphertext,
      ciphertextHeaderType: message['header_type'] as String? ?? 'dr.v1',
      now: _clock(),
    );
    sendMessageEnvelope(envelope);
  }

  void sendTypingIndicator(String recipientId, bool isTyping) {
    _emitGuarded(
      SocketEvent.messageTyping,
      _rateLimiters.typing,
      <String, dynamic>{
        'conversation_id': 'dm:$recipientId',
        'is_typing': isTyping,
      },
    );
  }

  /// Reports a conversation as read (SENT/DELIVERED/READ stay distinct).
  void markConversationAsRead(String conversationId, {String? messageId}) {
    _emitGuarded(
      SocketEvent.messageRead,
      _rateLimiters.message,
      <String, dynamic>{
        'conversation_id': conversationId,
        if (messageId != null) 'message_id': messageId,
      },
    );
  }

  /// Publishes own presence (online/last_seen). The server fans this out
  /// ONLY to relationships allowed by privacy settings — never globally.
  void updatePresence({required bool online}) {
    _emitGuarded(
      SocketEvent.presenceUpdate,
      _rateLimiters.presence,
      <String, dynamic>{
        'status': online ? 'online' : 'offline',
        'last_seen_ms': _clock().millisecondsSinceEpoch,
      },
    );
  }

  /// WebRTC SIGNALING only — audio/video media NEVER flows through
  /// Socket.IO (WebRTC peer connections carry the media).
  void sendCallOffer(String recipientId, Map<String, dynamic> offer) {
    _emitGuarded(
      SocketEvent.callOffer,
      _rateLimiters.signaling,
      _signalingPayload(recipientId, <String, dynamic>{'offer': offer}),
    );
  }

  void sendCallAnswer(String recipientId, Map<String, dynamic> answer) {
    _emitGuarded(
      SocketEvent.callAnswer,
      _rateLimiters.signaling,
      _signalingPayload(recipientId, <String, dynamic>{'answer': answer}),
    );
  }

  void sendIceCandidate(String recipientId, Map<String, dynamic> candidate) {
    _emitGuarded(
      SocketEvent.callIce,
      _rateLimiters.signaling,
      _signalingPayload(recipientId, <String, dynamic>{'candidate': candidate}),
    );
  }

  void endCall(String recipientId) {
    _emitGuarded(
      SocketEvent.callEnd,
      _rateLimiters.signaling,
      _signalingPayload(recipientId, const <String, dynamic>{}),
    );
  }

  /// Registers a handler for inbound message payloads. Handlers only run
  /// while authenticated.
  void onMessage(String eventType, Function(dynamic) handler) {
    _messageHandlers[eventType] = handler;
  }

  /// Registers a handler for simple inbound events.
  void onEvent(String eventType, Function() handler) {
    _eventHandlers[eventType] = handler;
  }

  /// Manual reconnect (after giving up, or app-triggered).
  void reconnect() {
    if (_status == SocketConnectionStatus.blocked) {
      LoggerService.warning('Reconnect refused: device blocked', tag: 'Socket');
      return;
    }
    _userInitiatedDisconnect = false;
    _reconnectPolicy.reset();
    _openSocket();
  }

  /// Graceful close. Cancels reconnection, invalidates the session and
  /// drops all timers. A later [connect]/[reconnect] starts from scratch.
  void disconnect() {
    _userInitiatedDisconnect = true;
    _cancelTimers();
    _teardownSocket();
    _clearSession();
    _outbox.clear();
    _setStatus(SocketConnectionStatus.disconnected);
    _connectionStatusController.add(false);
    _authStatusController.add(false);
    LoggerService.debug('Disconnected (user initiated)', tag: 'Socket');
  }

  void dispose() {
    disconnect();
    _connectivitySub?.cancel();
    _messageStreamController.close();
    _connectionStatusController.close();
    _authStatusController.close();
    _statusController.close();
  }

  // ==================== CONNECTION LIFECYCLE ====================

  void _openSocket() {
    if (_status == SocketConnectionStatus.blocked) return;

    final now = _clock();
    if (_authLockoutUntil != null && now.isBefore(_authLockoutUntil!)) {
      LoggerService.warning(
        'Local auth lockout active; waiting it out',
        tag: 'Socket',
      );
      _setStatus(SocketConnectionStatus.reconnecting);
      _scheduleReconnect(
        delay: _authLockoutUntil!.difference(now),
        immediate: false,
      );
      return;
    }

    final validation = SocketConfig.validateServerUrl(
      _config.serverUrl,
      allowInsecure: _config.allowInsecureTransport,
    );
    if (!validation.ok) {
      // Fail closed on insecure/invalid transport configuration.
      LoggerService.warning(
        'Server URL rejected (${validation.error!.name}): '
        'TLS is mandatory in production',
        tag: 'Socket',
      );
      _setStatus(SocketConnectionStatus.failed);
      _connectionStatusController.add(false);
      return;
    }

    _teardownSocket();
    _connectionGeneration++;
    _authAttemptsThisConnection = 0;
    _clearSession();
    _setStatus(SocketConnectionStatus.connecting);

    _socket = IO.io(
      _config.serverUrl,
      <String, dynamic>{
        // WebSocket is the primary transport; polling exists only as a
        // debug fallback (allowInsecureTransport implies debug).
        'transports': _config.transports,
        'autoConnect': false,
        // Library auto-reconnection DISABLED: our ReconnectPolicy drives
        // reconnection so every reconnect re-runs the full handshake.
        'reconnection': false,
        'forceNew': true,
        'timeout': _config.connectTimeout.inMilliseconds,
      },
    );

    _installHandlers();
    _startHeartbeatMonitor();
    _socket?.connect();
    LoggerService.info(
      'Connecting to ${SocketLog.url(_config.serverUrl)}',
      tag: 'Socket',
    );
  }

  void _installHandlers() {
    final socket = _socket;
    if (socket == null) return;

    socket.onConnect((_) {
      _heartbeatWatchdog.noteActivity();
      _setStatus(SocketConnectionStatus.awaitingChallenge);
      _connectionStatusController.add(true);
      _armAuthTimeout();
      // The server drives the handshake: wait for auth.challenge. The
      // client never emits identity proactively.
    });

    socket.onDisconnect((_) => _handleDisconnect('transport disconnected'));

    socket.onConnectError((error) {
      LoggerService.warning('Connect error (generic)', error: error, tag: 'Socket');
      _connectionStatusController.add(false);
      _handleDisconnect('connect error');
    });

    socket.onError((error) {
      LoggerService.warning(
        'Socket error (generic)',
        error: error,
        tag: 'Socket',
      );
      _heartbeatWatchdog.noteActivity();
    });

    socket.on(
      SocketEvent.authChallenge,
      (data) => unawaited(_handleChallenge(data)),
    );

    socket.on(SocketEvent.authSuccess, (data) {
      _heartbeatWatchdog.noteActivity();
      _handleAuthSuccess(data);
    });

    socket.on(SocketEvent.authFailure, (data) => _handleAuthFailure(data));

    socket.on(SocketEvent.messageAck, (data) {
      _heartbeatWatchdog.noteActivity();
      final messageId = data is Map ? data['message_id'] : null;
      if (messageId is String) {
        // ACK = the server RECEIVED and persisted it. Not "delivered".
        _outbox.markAcked(messageId);
      }
    });

    socket.on(SocketEvent.messageNew, (data) {
      _heartbeatWatchdog.noteActivity();
      _handleInboundMessage(data);
    });

    socket.on(SocketEvent.messageDelivered, (data) {
      _heartbeatWatchdog.noteActivity();
      final messageId = data is Map ? data['message_id'] : null;
      if (messageId is String) {
        _outbox.markStatus(messageId, MessageDeliveryStatus.delivered);
        _dispatchMessage(SocketEvent.messageDelivered, data);
      }
    });

    socket.on(SocketEvent.messageRead, (data) {
      _heartbeatWatchdog.noteActivity();
      _dispatchMessage(SocketEvent.messageRead, data);
    });

    socket.on(SocketEvent.messageTyping, (data) {
      _heartbeatWatchdog.noteActivity();
      _dispatchEvent(SocketEvent.messageTyping);
    });

    socket.on(SocketEvent.syncResponse, (data) {
      _heartbeatWatchdog.noteActivity();
      _handleSyncResponse(data);
    });

    socket.on(SocketEvent.presenceChanged, (data) {
      _heartbeatWatchdog.noteActivity();
      _dispatchMessage(SocketEvent.presenceChanged, data);
    });

    socket.on(SocketEvent.deviceAdded, (data) {
      _heartbeatWatchdog.noteActivity();
      _dispatchEvent(SocketEvent.deviceAdded);
    });

    socket.on(SocketEvent.deviceRevoked, (data) {
      _heartbeatWatchdog.noteActivity();
      _handleDeviceRevoked(data);
    });

    socket.on(SocketEvent.callOffer, (data) {
      _heartbeatWatchdog.noteActivity();
      _dispatchMessage(SocketEvent.callOffer, data);
    });
    socket.on(SocketEvent.callAnswer, (data) {
      _heartbeatWatchdog.noteActivity();
      _dispatchMessage(SocketEvent.callAnswer, data);
    });
    socket.on(SocketEvent.callIce, (data) {
      _heartbeatWatchdog.noteActivity();
      _dispatchMessage(SocketEvent.callIce, data);
    });
    socket.on(SocketEvent.callEnd, (data) {
      _heartbeatWatchdog.noteActivity();
      _dispatchMessage(SocketEvent.callEnd, data);
    });

    socket.on(SocketEvent.systemError, (data) {
      _heartbeatWatchdog.noteActivity();
      LoggerService.warning('Server system error (generic)', tag: 'Socket');
    });

    socket.on(SocketEvent.systemShutdown, (data) {
      _heartbeatWatchdog.noteActivity();
      LoggerService.info('Server shutdown notice; recycling', tag: 'Socket');
      _networkHandler.markResyncNeeded();
      _recycleConnection('server shutdown');
    });
  }

  // ==================== HANDSHAKE ====================

  Future<void> _handleChallenge(dynamic data) async {
    if (_status != SocketConnectionStatus.awaitingChallenge) return;
    final challenge = AuthChallenge.tryParse(data);
    final keyPair = _identityKeyPair;
    if (!challenge.isValid || keyPair == null) {
      // Fail closed: a malformed challenge is never answered.
      LoggerService.warning('Challenge invalid; recycling', tag: 'Socket');
      _recycleConnection('bad challenge');
      return;
    }
    if (challenge.isExpired(now: _clock()) ||
        challenge.hasImplausibleExpiry(now: _clock())) {
      LoggerService.warning(
        'Challenge expired/implausible; recycling',
        tag: 'Socket',
      );
      _recycleConnection('stale challenge');
      return;
    }
    if (_authAttemptsThisConnection >= _config.maxAuthAttemptsPerConnection) {
      LoggerService.warning('Auth attempt cap reached; recycling', tag: 'Socket');
      _recycleConnection('auth attempts exhausted');
      return;
    }
    if (!_rateLimiters.auth.allow()) {
      LoggerService.warning('Local auth rate limit; recycling', tag: 'Socket');
      _recycleConnection('auth rate limited');
      return;
    }

    _authAttemptsThisConnection++;
    final generation = _connectionGeneration;
    final response = await _signer.buildResponse(
      challenge: challenge,
      identityKeyPair: keyPair,
      accountId: _accountId ?? '',
      deviceId: _deviceId ?? '',
      novaId: _novaId ?? '',
      now: _clock(),
    );
    // The connection was recycled while signing: drop the response, the
    // pending connection owns the next handshake.
    if (response == null ||
        _socket == null ||
        generation != _connectionGeneration) {
      return;
    }
    _setStatus(SocketConnectionStatus.authenticating);
    _authTimeoutTimer?.cancel();
    _authTimeoutTimer = Timer(_config.authChallengeTimeout, () {
      LoggerService.warning('Auth verdict timeout; recycling', tag: 'Socket');
      _recycleConnection('auth timeout');
    });
    // Only the signature + identity claims go on the wire. The public key
    // is NOT sent: the server verifies against the REGISTERED key.
    _socket?.emit(SocketEvent.authResponse, response.toMap());
    LoggerService.debug(
      'Auth response sent (challenge ${SocketLog.id(challenge.challengeId)})',
      tag: 'Socket',
    );
  }

  void _handleAuthSuccess(dynamic data) {
    final success = AuthSuccess.tryParse(data);
    if (!success.isValid) {
      _recycleConnection('malformed auth.success');
      return;
    }
    final session = SocketSession.fromAuthSuccess(
      success,
      expectedAccountId: _accountId ?? '',
      expectedDeviceId: _deviceId ?? '',
      expectedNovaId: _novaId ?? '',
    );
    if (!session.isActive) {
      // The server echoed identities that are not OURS -> protocol
      // violation, fail closed.
      LoggerService.warning(
        'auth.success identity mismatch; recycling',
        tag: 'Socket',
      );
      _recycleConnection('identity mismatch');
      return;
    }
    _session = session;
    _consecutiveAuthFailures = 0;
    _authLockoutUntil = null;
    _authTimeoutTimer?.cancel();
    _reconnectPolicy.reset();
    _setStatus(SocketConnectionStatus.authenticated);
    _authStatusController.add(true);
    LoggerService.info(
      'Authenticated (session ${SocketLog.id(session.sessionId)})',
      tag: 'Socket',
    );
    // Presence is pushed on auth (server fans out only to allowed peers).
    updatePresence(online: true);
    _requestSync();
    _flushOutbox();
    _dispatchEvent('authenticated');
  }

  void _handleAuthFailure(dynamic data) {
    _authTimeoutTimer?.cancel();
    final code = parseAuthFailureCode(data);
    // Only the generic code is logged — never a detailed reason.
    LoggerService.warning('Auth failed: ${code.name}', tag: 'Socket');
    _consecutiveAuthFailures++;
    _authStatusController.add(false);

    if (code == SocketAuthFailureCode.deviceRevoked) {
      _blockDevice();
      return;
    }
    if (code == SocketAuthFailureCode.rateLimited ||
        _consecutiveAuthFailures >= _config.authLockoutAfterFailures) {
      _authLockoutUntil = _clock().add(_config.authLockoutDuration);
    }
    _recycleConnection('auth failed');
  }

  void _blockDevice() {
    LoggerService.warning(
      'Device revoked/blocked: disconnecting and refusing reconnection',
      tag: 'Socket',
    );
    _cancelTimers();
    _teardownSocket();
    _clearSession();
    _outbox.clear();
    _setStatus(SocketConnectionStatus.blocked);
    _connectionStatusController.add(false);
    _authStatusController.add(false);
  }

  void _handleDeviceRevoked(dynamic data) {
    final revokedDeviceId = data is Map ? data['device_id'] : null;
    if (revokedDeviceId is! String || revokedDeviceId == _deviceId) {
      // Our device (or an unspecified broadcast): self-revocation.
      _blockDevice();
      return;
    }
    // A sibling device was revoked: notify the app, keep the session.
    _dispatchEvent(SocketEvent.deviceRevoked);
  }

  // ==================== EVENTS / MESSAGING ====================

  void _emitGuarded(
    String event,
    TokenBucketRateLimiter limiter,
    Map<String, dynamic> payload,
  ) {
    if (!isAuthenticated) {
      LoggerService.warning(
        'Emit refused (not authenticated): $event',
        tag: 'Socket',
      );
      return;
    }
    if (!isClientEmittableEvent(event)) {
      LoggerService.warning(
        'Emit refused (not client-emittable): $event',
        tag: 'Socket',
      );
      return;
    }
    if (!_rateLimiters.aggregate.allow() || !limiter.allow()) {
      LoggerService.warning('Emit refused (rate limited): $event', tag: 'Socket');
      return;
    }
    _socket?.emit(event, payload);
  }

  Map<String, dynamic> _signalingPayload(
    String recipientId,
    Map<String, dynamic> body,
  ) =>
      <String, dynamic>{
        ...body,
        'peer_account_id': recipientId,
        'device_id': _deviceId,
        // WebRTC SDP/ICE are signaling data, not E2EE content — the media
        // itself flows ONLY over the WebRTC peer connection.
      };

  void _flushOutbox() {
    if (!isAuthenticated) return;
    final now = _clock();
    for (final entry in _outbox.dueEntries()) {
      if (!_rateLimiters.message.allow() || !_rateLimiters.aggregate.allow()) {
        // Preserve remaining entries for the next flush window.
        return;
      }
      // Same message_id on every retry — server-side dedup makes the send
      // idempotent across reconnections.
      _socket?.emit(SocketEvent.messageSend, entry.envelope.toWire());
      _outbox.markAttempted(entry.envelope.messageId, now);
    }
    _outbox.cleanup();
  }

  void _requestSync() {
    _emitGuarded(
      SocketEvent.syncRequest,
      _rateLimiters.sync,
      <String, dynamic>{
        'last_cursor': _lastSyncCursor,
        'device_id': _deviceId,
      },
    );
  }

  void _handleSyncResponse(dynamic data) {
    if (data is! Map) return;
    final cursor = data['cursor'];
    if (cursor is int && cursor > _lastSyncCursor) {
      _lastSyncCursor = cursor;
    }
    final events = data['events'];
    if (events is List) {
      for (final event in events) {
        _dispatchMessage('sync.event', event);
      }
    }
    _networkHandler.resyncCompleted();
    _dispatchEvent('synced');
  }

  void _handleInboundMessage(dynamic data) {
    if (!isAuthenticated) return;
    final seq = data is Map ? data['server_seq'] : null;
    final parsed = seq is int
        ? MessageEnvelope.tryParseInbound(data, serverSeq: seq)
        : null;
    if (parsed == null) {
      LoggerService.warning('Inbound envelope invalid; dropped', tag: 'Socket');
      return;
    }
    final result = _gapDetector.feed(
      conversationId: parsed.conversationId,
      messageId: parsed.messageId,
      serverSeq: parsed.serverSeq,
    );
    switch (result) {
      case SequenceGapDetector.FeedResult.duplicate:
        return; // Already applied — never process twice.
      case SequenceGapDetector.FeedResult.gapDetected:
        // Missing predecessors: ask the server for the missing range.
        _networkHandler.markResyncNeeded();
        _requestSync();
      case SequenceGapDetector.FeedResult.accepted:
      case SequenceGapDetector.FeedResult.buffered:
        break;
    }
    _dispatchMessage(SocketEvent.messageNew, data);
  }

  void _dispatchMessage(String type, dynamic data) {
    if (!isAuthenticated) return; // No events before authentication.
    if (data is Map) {
      _messageStreamController.add(Map<String, dynamic>.from(data));
    }
    for (final handler in _messageHandlers.values) {
      try {
        handler(data);
        // A misbehaving handler must not break the transport.
      } catch (e) {
        LoggerService.error('Handler error', error: e, tag: 'Socket');
      }
    }
  }

  void _dispatchEvent(String type) {
    // Lifecycle events are only dispatched while authenticated (the
    // 'authenticated' event itself is dispatched right after the status
    // flips, so the equality check below is intentionally inclusive).
    if (_status != SocketConnectionStatus.authenticated) {
      return;
    }
    for (final handler in _eventHandlers.values) {
      try {
        handler();
      } catch (e) {
        LoggerService.error('Handler error', error: e, tag: 'Socket');
      }
    }
  }

  // ==================== DISCONNECT / RECONNECT ====================

  void _handleDisconnect(String reason) {
    _connectionStatusController.add(false);
    _authStatusController.add(false);
    _clearSession();
    if (_userInitiatedDisconnect) {
      _setStatus(SocketConnectionStatus.disconnected);
      return;
    }
    if (_status == SocketConnectionStatus.blocked) return;
    _networkHandler.markResyncNeeded();
    _scheduleReconnect(immediate: false);
  }

  /// Tears the connection down and schedules a reconnect. Used for local
  /// protocol violations and network transitions (immediate reconnect).
  void _recycleConnection(String reason, {bool immediate = false}) {
    // Sessions are single-use per connection: dropping the socket always
    // invalidates the session (a full re-handshake follows).
    _cancelAuthTimeout();
    _teardownSocket();
    _clearSession();
    if (_userInitiatedDisconnect || _status == SocketConnectionStatus.blocked) {
      return;
    }
    _networkHandler.markResyncNeeded();
    _scheduleReconnect(immediate: immediate);
  }

  void _scheduleReconnect({required bool immediate, Duration? delay}) {
    _reconnectTimer?.cancel();
    if (_userInitiatedDisconnect || _status == SocketConnectionStatus.blocked) {
      return;
    }
    if (immediate) {
      _reconnectPolicy.reset();
      _setStatus(SocketConnectionStatus.reconnecting);
      _reconnectTimer = Timer(Duration.zero, _openSocket);
      return;
    }
    if (_reconnectPolicy.exhausted) {
      // Bounded: no infinite reconnect loops. Wait for a connectivity
      // change (bindConnectivity) or an explicit reconnect() call.
      LoggerService.warning(
        'Reconnect attempts exhausted; giving up until connectivity change '
        'or manual reconnect',
        tag: 'Socket',
      );
      _setStatus(SocketConnectionStatus.failed);
      return;
    }
    final wait = delay ?? _reconnectPolicy.nextDelay();
    _setStatus(SocketConnectionStatus.reconnecting);
    LoggerService.debug(
      'Reconnecting in ${wait.inMilliseconds}ms '
      '(attempt ${_reconnectPolicy.attempt})',
      tag: 'Socket',
    );
    _reconnectTimer = Timer(wait, _openSocket);
  }

  void _armAuthTimeout() {
    _authTimeoutTimer?.cancel();
    _authTimeoutTimer = Timer(_config.authChallengeTimeout, () {
      LoggerService.warning('No auth challenge arrived; recycling', tag: 'Socket');
      _recycleConnection('challenge timeout');
    });
  }

  // ==================== HEARTBEAT ====================

  void _startHeartbeatMonitor() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_config.heartbeatCheckInterval, (_) {
      if (!isConnected) return;
      final action = _heartbeatWatchdog.evaluate();
      if (action == HeartbeatAction.disconnectDeadConnection) {
        LoggerService.warning('Dead connection detected; recycling', tag: 'Socket');
        _recycleConnection('heartbeat silence');
      }
    });
  }

  // ==================== TEARDOWN ====================

  void _cancelTimers() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _authTimeoutTimer?.cancel();
    _authTimeoutTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _cancelAuthTimeout() {
    _authTimeoutTimer?.cancel();
    _authTimeoutTimer = null;
  }

  void _teardownSocket() {
    final socket = _socket;
    _socket = null;
    if (socket == null) return;
    try {
      socket.dispose();
    } catch (e) {
      LoggerService.debug(
        'Socket dispose error (ignored)',
        error: e,
        tag: 'Socket',
      );
    }
  }

  void _clearSession() {
    // Sessions are single-use per connection: cleared, never resurrected.
    _session = SocketSession.none;
  }

  void _setStatus(SocketConnectionStatus next) {
    if (_status == next) return;
    _status = next;
    _statusController.add(next);
  }
}

final webSocketServiceProvider = Provider<WebSocketService>((ref) {
  final service = WebSocketService();
  ref.onDispose(service.dispose);
  return service;
});
