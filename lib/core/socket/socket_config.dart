/// Audited Socket.IO client configuration for NovaApp.
///
/// Every value below is a deliberate decision documented in
/// docs/SOCKET_ARCHITECTURE.md (section "Configuración Socket.IO").
///
/// Summary of decisions:
///   * Transport: WebSocket ONLY in production. Long-polling fallback is
///     allowed ONLY in debug builds (documented reason: corporate proxies /
///     captive portals during development). There is no production fallback
///     because WebSocket availability is a hard requirement for the app and
///     silently degrading to polling hides connectivity problems while
///     increasing server cost and attack surface.
///   * Library auto-reconnection is DISABLED ('reconnection': false).
///     Reconnection is driven by our own [ReconnectPolicy] (exponential
///     backoff + full jitter + bounded attempts) so the behavior is
///     deterministic, testable, and integrates with the re-authentication
///     flow (a reconnect without re-authentication is never allowed).
///   * TLS: wss:// (https://) mandatory. ws:// is rejected unless the caller
///     explicitly enables [allowInsecureTransport] AND the build is a debug
///     build. Certificate validation is never disabled.
class SocketConfig {
  const SocketConfig({
    this.serverUrl = '',
    this.transports = const ['websocket'],
    this.connectTimeout = const Duration(seconds: 15),
    this.authChallengeTimeout = const Duration(seconds: 20),
    this.maxAuthAttemptsPerConnection = 3,
    this.authLockoutAfterFailures = 5,
    this.authLockoutDuration = const Duration(minutes: 2),
    this.silenceThreshold = const Duration(seconds: 75),
    this.heartbeatCheckInterval = const Duration(seconds: 15),
    this.ackTimeout = const Duration(seconds: 10),
    this.allowInsecureTransport = false,
  });

  /// Debug configuration: allows polling fallback and insecure transport.
  /// NEVER use in release builds.
  factory SocketConfig.debug({required String serverUrl}) => SocketConfig(
        serverUrl: serverUrl,
        transports: const ['websocket', 'polling'],
        allowInsecureTransport: true,
      );

  /// Validates a server URL against the transport security policy.
  /// Returns a [SocketUrlValidation]; check `.ok` and `.error`.
  static SocketUrlValidation validateServerUrl(
    String url, {
    required bool allowInsecure,
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return const SocketUrlValidation(
        ok: false,
        error: SocketUrlError.invalidUrl,
      );
    }
    final secure = uri.scheme == 'wss' || uri.scheme == 'https';
    final insecure = uri.scheme == 'ws' || uri.scheme == 'http';
    if (!secure && !insecure) {
      return const SocketUrlValidation(
        ok: false,
        error: SocketUrlError.invalidScheme,
      );
    }
    if (insecure && !allowInsecure) {
      // Production rule: TLS is mandatory, no exceptions.
      return const SocketUrlValidation(
        ok: false,
        error: SocketUrlError.insecureTransportRejected,
      );
    }
    return SocketUrlValidation(ok: true, error: null, uri: uri);
  }

  /// Server base URL, e.g. `wss://realtime.novaapp.example`.
  final String serverUrl;

  /// Allowed engine.io transports. WebSocket is the primary (and, in
  /// production, only) transport. Polling may be appended for debug builds
  /// only — never as the primary mechanism.
  final List<String> transports;

  /// Handshake + upgrade timeout.
  final Duration connectTimeout;

  /// Time the client waits for `auth.challenge` / `auth.success` before
  /// giving up on the handshake and reconnecting with backoff.
  final Duration authChallengeTimeout;

  /// Maximum auth.response attempts on a single connection before the client
  /// closes it (server also enforces this — defense in depth).
  final int maxAuthAttemptsPerConnection;

  /// Consecutive failed authentications (across connections) after which the
  /// client enters a local lockout to avoid hammering auth.challenge/response.
  final int authLockoutAfterFailures;

  /// Duration of the local auth lockout.
  final Duration authLockoutDuration;

  /// If the transport reports "connected" but no packet arrives for this
  /// long, the connection is considered dead and is force-closed.
  /// Default 75s > typical engine.io pingInterval(25s) + pingTimeout(20s),
  /// so a healthy connection never trips the watchdog.
  final Duration silenceThreshold;

  /// How often the heartbeat watchdog checks the last-activity timestamp.
  /// Kept at 15s so the check itself costs ~nothing on battery; the watchdog
  /// sends NO extra packets (engine.io ping/pong already exists).
  final Duration heartbeatCheckInterval;

  /// How long the client waits for a server `message.ack` before marking the
  /// outgoing message as failed/retryable.
  final Duration ackTimeout;

  /// Debug-only escape hatch that permits ws:// (non-TLS). Must never be set
  /// in release builds; see [validateServerUrl].
  final bool allowInsecureTransport;

  /// Copy of this config with a different server URL.
  SocketConfig withServerUrl(String url) => SocketConfig(
        serverUrl: url,
        transports: transports,
        connectTimeout: connectTimeout,
        authChallengeTimeout: authChallengeTimeout,
        maxAuthAttemptsPerConnection: maxAuthAttemptsPerConnection,
        authLockoutAfterFailures: authLockoutAfterFailures,
        authLockoutDuration: authLockoutDuration,
        silenceThreshold: silenceThreshold,
        heartbeatCheckInterval: heartbeatCheckInterval,
        ackTimeout: ackTimeout,
        allowInsecureTransport: allowInsecureTransport,
      );
}

/// Why a server URL was rejected.
enum SocketUrlError {
  /// Not a parseable absolute URL.
  invalidUrl,

  /// Scheme is not ws/wss/http/https.
  invalidScheme,

  /// ws:// or http:// used while TLS is mandatory.
  insecureTransportRejected,
}

/// Outcome of [SocketConfig.validateServerUrl].
class SocketUrlValidation {
  const SocketUrlValidation({required this.ok, required this.error, this.uri});

  final bool ok;
  final SocketUrlError? error;
  final Uri? uri;
}

/// Rate limit presets (client-enforced politeness; the server applies its own,
/// stricter-or-equal limits — see docs/SOCKET_SECURITY.md).
///
/// Units are "tokens per minute" with a bucket capacity equal to the value
/// shown (burst = sustained rate, conservative by design).
abstract final class SocketRateLimitPresets {
  /// auth.response attempts. Protects auth.challenge/response against
  /// brute-force and abuse.
  static const int authPerMinute = 5;

  /// Outgoing E2EE message envelopes.
  static const int messagePerMinute = 30;

  /// Typing indicators (start/stop pairs included).
  static const int typingPerMinute = 12;

  /// WebRTC signaling events (offer/answer/ice are bursty).
  static const int signalingPerMinute = 60;

  /// sync.request (reconnection storms must not spam sync).
  static const int syncPerMinute = 6;

  /// Own-presence updates (online/offline/last_seen).
  static const int presencePerMinute = 12;

  /// Aggregate cap for ALL client-emitted events as a safety net.
  static const int totalEventsPerMinute = 120;
}
