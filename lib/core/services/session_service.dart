import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:novaapp/core/constants.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';

/// Manages active sessions across devices.
///
/// A session = one authenticated JWT per device.
/// Sessions are tracked server-side for:
///   - Visibility: "where am I logged in?"
///   - Revocation: "log me out everywhere"
///   - Security alerts: "new device logged in"

class SessionService {
  final SupabaseClient? _client;

  SessionService(this._client);

  // ===== SESSION TRACKING =====

  /// Records a new session after successful login.
  Future<bool> createSession({
    required String novaId,
    required String deviceId,
    required String jwtToken,
    String? ipAddress,
    String? userAgent,
  }) async {
    if (_client == null) return false;
    try {
      await _client!.from('sessions').insert({
        'nova_id': novaId,
        'device_id': deviceId,
        'jwt_token_hash': _hashToken(jwtToken),
        'ip_address': ipAddress,
        'user_agent': userAgent,
        'created_at': DateTime.now().toIso8601String(),
        'last_active_at': DateTime.now().toIso8601String(),
        'expires_at': DateTime.now().add(const Duration(hours: 24)).toIso8601String(),
      });
      LoggerService.info('Session created for device $deviceId', tag: 'Session');
      return true;
    } catch (e) {
      LoggerService.error('Session creation failed', error: e, tag: 'Session');
      return false;
    }
  }

  /// Updates the last active timestamp.
  Future<void> touchSession(String deviceId) async {
    if (_client == null) return;
    try {
      await _client!.from('sessions').update({
        'last_active_at': DateTime.now().toIso8601String(),
      }).eq('device_id', deviceId);
    } catch (_) {}
  }

  // ===== SESSION LIST =====

  /// Returns all active sessions for a Nova ID.
  Future<List<Map<String, dynamic>>> getActiveSessions(String novaId) async {
    if (_client == null) return [];
    try {
      final result = await _client!
          .from('sessions')
          .select('''
            device_id, ip_address, user_agent, created_at, last_active_at, expires_at,
            devices!inner(device_name, platform, status)
          ''')
          .eq('nova_id', novaId)
          .eq('devices.status', 'active')
          .order('last_active_at', ascending: false);
      return List<Map<String, dynamic>>.from(result);
    } catch (e) {
      LoggerService.error('Failed to fetch sessions', error: e, tag: 'Session');
      return [];
    }
  }

  // ===== REVOCATION =====

  /// Revokes a specific session.
  Future<bool> revokeSession(String deviceId) async {
    if (_client == null) return false;
    try {
      await _client!.from('sessions').delete().eq('device_id', deviceId);
      LoggerService.info('Session revoked: $deviceId', tag: 'Session');
      return true;
    } catch (e) {
      LoggerService.error('Session revocation failed', error: e, tag: 'Session');
      return false;
    }
  }

  /// Revokes all sessions except the current one.
  Future<int> revokeAllExcept(String novaId, String keepDeviceId) async {
    if (_client == null) return 0;
    try {
      final result = await _client!.from('sessions').delete()
        .eq('nova_id', novaId)
        .neq('device_id', keepDeviceId);
      LoggerService.info('Revoked all sessions except $keepDeviceId', tag: 'Session');
      return result.length;
    } catch (e) {
      LoggerService.error('Bulk session revocation failed', error: e, tag: 'Session');
      return 0;
    }
  }

  // ===== CLEANUP =====

  /// Removes expired sessions.
  Future<int> cleanupExpiredSessions() async {
    if (_client == null) return 0;
    try {
      final result = await _client!.from('sessions').delete()
        .lt('expires_at', DateTime.now().toIso8601String());
      return result.length;
    } catch (_) {
      return 0;
    }
  }

  // ===== HELPERS =====

  /// Hashes a JWT token for storage (never store raw tokens).
  static String _hashToken(String token) {
    // Simple hash for tracking purposes (not cryptographic security)
    return token.hashCode.toRadixString(16);
  }

  /// Returns true if the session is still valid (not expired).
  static bool isSessionValid(Map<String, dynamic> session) {
    final expiresAt = session['expires_at'] as String?;
    if (expiresAt == null) return false;
    return DateTime.parse(expiresAt).isAfter(DateTime.now());
  }
}

final sessionServiceProvider = Provider<SessionService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SessionService(client);
});
