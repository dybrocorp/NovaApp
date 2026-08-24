/// Generic, non-enumerable protocol error codes.
///
/// Rule: the server NEVER reveals which specific check failed for a
/// cryptographic rejection. Every handshake failure is `AUTH_FAILED`
/// (prevents account/device enumeration and aids nothing to an attacker).
/// Distinct codes exist only where honest clients must change behavior:
/// RATE_LIMITED (back off) and DEVICE_REVOKED (stop reconnecting).
abstract final class SocketErrorCode {
  static const String authFailed = 'AUTH_FAILED';
  static const String rateLimited = 'RATE_LIMITED';
  static const String deviceRevoked = 'DEVICE_REVOKED';
  static const String sessionExpired = 'SESSION_EXPIRED';
  static const String forbidden = 'FORBIDDEN';
  static const String duplicate = 'DUPLICATE';
  static const String payloadInvalid = 'PAYLOAD_INVALID';
  static const String serverClosing = 'SERVER_CLOSING';
}
