import 'dart:convert';
import 'dart:math';

/// REFERENCE implementation of the server-side session registry.
///
/// After a successful handshake the server creates a session:
///   * random 256-bit id;
///   * TTL (default 24h) with sliding renewal on activity;
///   * bound to (accountId, deviceId, novaId);
///   * revocable individually or by device;
///   * invalidated automatically when the owning device is revoked.
///
/// Events are authorized against the session attached to the socket —
/// the client never re-sends identity, signatures or tokens per event.
///
/// Production mapping: Redis hash with TTL + `sessions` table in Supabase
/// (see docs/SOCKET_SERVER_ARCHITECTURE.md).
class SessionRegistry {
  SessionRegistry({
    this.sessionTtl = const Duration(hours: 24),
    DateTime Function()? clock,
    Random? random,
  })  : _clock = clock ?? DateTime.now,
        _random = random ?? Random.secure();

  final Duration sessionTtl;
  final DateTime Function() _clock;
  final Random _random;

  final Map<String, RegisteredSession> _sessions = {};

  /// Creates a session after a verified handshake. Evicts any previous
  /// live session of the SAME DEVICE first: one live session per device —
  /// a device that reconnects (new socket, new handshake) immediately
  /// invalidates its previous session; it can never be resurrected.
  RegisteredSession create({
    required String socketKey,
    required String accountId,
    required String deviceId,
    required String novaId,
  }) {
    _evictByDevice(deviceId);
    final session = RegisteredSession(
      sessionId: _randomId(),
      socketKey: socketKey,
      accountId: accountId,
      deviceId: deviceId,
      novaId: novaId,
      createdAt: _clock(),
      expiresAt: _clock().add(sessionTtl),
      revoked: false,
    );
    _sessions[session.sessionId] = session;
    return session;
  }

  /// Validates a session for event authorization. Sliding renewal on success
  /// keeps active devices logged in without extending idle ones.
  SessionValidation validate(String sessionId, {required String socketKey}) {
    final session = _sessions[sessionId];
    if (session == null) return SessionValidation.invalid;
    if (session.revoked) return SessionValidation.revoked;
    final now = _clock();
    if (now.isAfter(session.expiresAt)) {
      _sessions.remove(sessionId);
      return SessionValidation.expired;
    }
    if (session.socketKey != socketKey) return SessionValidation.invalid;
    _renew(session, now);
    return SessionValidation.ok;
  }

  /// Revokes one session (logout of one socket).
  void revoke(String sessionId) => _sessions.remove(sessionId);

  /// Revokes every session of a device (device revoked / logout device).
  /// Returns the number of sessions killed.
  int revokeByDevice(String deviceId) {
    final doomed = _sessions.values
        .where((s) => s.deviceId == deviceId)
        .map((s) => s.sessionId)
        .toList();
    for (final id in doomed) {
      _sessions.remove(id);
    }
    return doomed.length;
  }

  /// True when the device has at least one live session.
  bool deviceHasLiveSession(String deviceId) =>
      _sessions.values.any((s) => s.deviceId == deviceId);

  int get liveCount => _sessions.length;

  void _evictByDevice(String deviceId) {
    _sessions.removeWhere((_, s) => s.deviceId == deviceId);
  }

  void _renew(RegisteredSession session, DateTime now) {
    final renewed = RegisteredSession(
      sessionId: session.sessionId,
      socketKey: session.socketKey,
      accountId: session.accountId,
      deviceId: session.deviceId,
      novaId: session.novaId,
      createdAt: session.createdAt,
      expiresAt: now.add(sessionTtl),
      revoked: session.revoked,
    );
    _sessions[session.sessionId] = renewed;
  }

  String _randomId() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes);
  }
}

enum SessionValidation { ok, invalid, expired, revoked }

/// A session as stored server-side (reference model).
class RegisteredSession {
  const RegisteredSession({
    required this.sessionId,
    required this.socketKey,
    required this.accountId,
    required this.deviceId,
    required this.novaId,
    required this.createdAt,
    required this.expiresAt,
    required this.revoked,
  });

  final String sessionId;
  final String socketKey;
  final String accountId;
  final String deviceId;
  final String novaId;
  final DateTime createdAt;
  final DateTime expiresAt;
  final bool revoked;

  Map<String, dynamic> toAuthSuccessWire() => <String, dynamic>{
        'session_id': sessionId,
        'account_id': accountId,
        'device_id': deviceId,
        'nova_id': novaId,
        'expires_at_ms': expiresAt.millisecondsSinceEpoch,
      };
}
