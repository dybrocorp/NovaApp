/**
 * Generic, non-enumerable protocol error codes.
 *
 * Mirror of `lib/core/socket/protocol/protocol_errors.dart` (PASO 4).
 *
 * Rule: the server NEVER reveals which specific check failed for a
 * cryptographic rejection. Every handshake failure is `AUTH_FAILED`
 * (prevents account/device enumeration). Distinct codes exist only where
 * honest clients must change behavior: RATE_LIMITED (back off),
 * DEVICE_REVOKED (stop reconnecting), SESSION_EXPIRED (re-authenticate).
 */
export const SocketErrorCode = {
  authFailed: 'AUTH_FAILED',
  rateLimited: 'RATE_LIMITED',
  deviceRevoked: 'DEVICE_REVOKED',
  sessionExpired: 'SESSION_EXPIRED',
  forbidden: 'FORBIDDEN',
  duplicate: 'DUPLICATE',
  payloadInvalid: 'PAYLOAD_INVALID',
  serverClosing: 'SERVER_CLOSING',
} as const;

export type SocketErrorCodeValue =
  (typeof SocketErrorCode)[keyof typeof SocketErrorCode];
