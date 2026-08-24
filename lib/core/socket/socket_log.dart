/// Log-redaction helpers for the socket layer.
///
/// NEVER log: private keys, plaintext messages, session secrets, challenge
/// secrets, sensitive tokens, E2EE plaintext, signatures.
///
/// Identifiers (device ids, session ids, message ids) are logged as short
/// prefixes so operators can correlate events without keeping a full
/// identifier trail (privacy + data minimization).
abstract final class SocketLog {
  /// Returns a short, non-reversible-looking display prefix for an id:
  /// `SocketLog.id('a1b2c3d4-...') == 'a1b2…'`. Empty ids stay empty.
  static String id(String? identifier) {
    if (identifier == null || identifier.isEmpty) return '—';
    if (identifier.length <= 4) return '…';
    return '${identifier.substring(0, 4)}…';
  }

  /// Redacts a URL: keeps scheme+host (needed for ops), drops path/query
  /// (query strings historically carry tokens).
  static String url(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return '—';
    final defaultPort = uri.scheme == 'wss' || uri.scheme == 'https'
        ? 443
        : (uri.scheme == 'ws' || uri.scheme == 'http' ? 80 : 0);
    final port = uri.hasPort && uri.port != defaultPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }

  /// Fields that must NEVER reach a log line. Used by scrub() when logging
  /// structured data.
  static const Set<String> redactedKeys = <String>{
    'signature',
    'challenge',
    'challenge_bytes',
    'session_id',
    'token',
    'jwt',
    'ciphertext',
    'plaintext',
    'private_key',
    'public_key',
    'secret',
  };

  /// Returns a copy of [data] safe for logging: values of sensitive keys are
  /// replaced by '[REDACTED]' (key names are kept so patterns remain
  /// debuggable).
  static Map<String, dynamic> scrub(Map<String, dynamic> data) {
    return data.map((key, value) {
      if (redactedKeys.contains(key.toLowerCase())) {
        return MapEntry(key, '[REDACTED]');
      }
      if (value is Map<String, dynamic>) {
        return MapEntry(key, scrub(value));
      }
      return MapEntry(key, value);
    });
  }
}
