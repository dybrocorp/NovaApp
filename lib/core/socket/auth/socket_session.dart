import 'auth_payloads.dart';

/// Client-side view of an authenticated socket session.
///
/// After `auth.success` the client holds an opaque session id; it does NOT
/// send identity or signatures with every event — the server maps
/// socket <-> session server-side (source of truth: SessionRegistry /
/// `sessions` table, see docs/SOCKET_SERVER_ARCHITECTURE.md).
///
/// Rules enforced by this class:
///   * A session is bound to exactly one (accountId, deviceId, novaId);
///     a server response naming different identities is rejected locally.
///   * A session has an expiry; expired sessions are never used.
///   * A session can be invalidated (revocation, disconnect); once cleared
///     it can NEVER be resurrected — a reconnect requires a full new
///     handshake (new challenge + new signature + new session).
class SocketSession {
  const SocketSession({
    required this.sessionId,
    required this.accountId,
    required this.deviceId,
    required this.novaId,
    required this.expiresAtMs,
  });

  factory SocketSession.fromAuthSuccess(
    AuthSuccess success, {
    required String expectedAccountId,
    required String expectedDeviceId,
    required String expectedNovaId,
  }) {
    if (!success.isValid) return const SocketSession.cleared();
    // Identity binding: the server must echo OUR identities. Anything else
    // is a protocol violation (or a misrouted session) — fail closed.
    final matches = success.accountId == expectedAccountId &&
        success.deviceId == expectedDeviceId &&
        success.novaId == expectedNovaId;
    if (!matches) return const SocketSession.cleared();
    return SocketSession(
      sessionId: success.sessionId,
      accountId: success.accountId,
      deviceId: success.deviceId,
      novaId: success.novaId,
      expiresAtMs: success.expiresAtMs,
    );
  }

  /// Sentinel for "no usable session".
  const SocketSession.cleared()
      : sessionId = '',
        accountId = '',
        deviceId = '',
        novaId = '',
        expiresAtMs = 0;

  final String sessionId;
  final String accountId;
  final String deviceId;
  final String novaId;
  final int expiresAtMs;

  bool get isActive => sessionId.isNotEmpty;

  bool isExpired({required DateTime now}) =>
      !isActive || expiresAtMs <= now.millisecondsSinceEpoch;

  /// Usable = present and not expired.
  bool isUsable({required DateTime now}) => isActive && !isExpired(now: now);

  /// A session is single-use per connection: any disconnect invalidates it.
  /// The next connection goes through a brand-new handshake.
  static const SocketSession none = SocketSession.cleared();
}
