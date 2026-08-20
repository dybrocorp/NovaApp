import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:novaapp/core/constants.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';

/// Manages device registration, revocation, and active sessions.
///
/// Each device has:
///   - Device ID (local, unique per install)
///   - Device fingerprint (platform + model + OS version)
///   - Registration status (pending, active, revoked)
///   - Last seen timestamp
///
/// New devices require approval from an existing device.

class DeviceService {
  final SupabaseClient? _client;

  DeviceService(this._client);

  // ===== REGISTRATION =====

  /// Registers a new device. Returns true on success.
  Future<bool> registerDevice({
    required String novaId,
    required String deviceId,
    required String deviceName,
    required String platform,
    required String osVersion,
    required String appVersion,
    String? pushToken,
  }) async {
    if (_client == null) return false;
    try {
      await _client!.from('devices').upsert({
        'nova_id': novaId,
        'device_id': deviceId,
        'device_name': deviceName,
        'platform': platform,
        'os_version': osVersion,
        'app_version': appVersion,
        'push_token': pushToken,
        'status': 'active',
        'last_seen_at': DateTime.now().toIso8601String(),
        'registered_at': DateTime.now().toIso8601String(),
      }, onConflict: 'device_id');
      LoggerService.info('Device registered: $deviceId', tag: 'Device');
      return true;
    } catch (e) {
      LoggerService.error('Device registration failed', error: e, tag: 'Device');
      return false;
    }
  }

  /// Updates the last seen timestamp for a device.
  Future<void> updateLastSeen(String deviceId) async {
    if (_client == null) return;
    try {
      await _client!.from('devices').update({
        'last_seen_at': DateTime.now().toIso8601String(),
      }).eq('device_id', deviceId);
    } catch (_) {
      // Non-critical, ignore
    }
  }

  // ===== DEVICE LIST =====

  /// Returns all active devices for a Nova ID.
  Future<List<Map<String, dynamic>>> getDevices(String novaId) async {
    if (_client == null) return [];
    try {
      final result = await _client!
          .from('devices')
          .select('device_id, device_name, platform, os_version, status, last_seen_at, registered_at')
          .eq('nova_id', novaId)
          .order('registered_at', ascending: false);
      return List<Map<String, dynamic>>.from(result);
    } catch (e) {
      LoggerService.error('Failed to fetch devices', error: e, tag: 'Device');
      return [];
    }
  }

  /// Returns the count of active devices.
  Future<int> getActiveDeviceCount(String novaId) async {
    if (_client == null) return 0;
    try {
      final result = await _client!
          .from('devices')
          .select('device_id')
          .eq('nova_id', novaId)
          .eq('status', 'active');
      return result.length;
    } catch (_) {
      return 0;
    }
  }

  // ===== REVOCATION =====

  /// Revokes a specific device (removes its access).
  Future<bool> revokeDevice(String deviceId) async {
    if (_client == null) return false;
    try {
      await _client!.from('devices').update({
        'status': 'revoked',
        'revoked_at': DateTime.now().toIso8601String(),
      }).eq('device_id', deviceId);
      LoggerService.info('Device revoked: $deviceId', tag: 'Device');
      return true;
    } catch (e) {
      LoggerService.error('Device revocation failed', error: e, tag: 'Device');
      return false;
    }
  }

  /// Revokes all devices except the specified one (force logout everywhere else).
  Future<int> revokeAllExcept(String novaId, String keepDeviceId) async {
    if (_client == null) return 0;
    try {
      final result = await _client!.from('devices').update({
        'status': 'revoked',
        'revoked_at': DateTime.now().toIso8601String(),
      }).eq('nova_id', novaId).neq('device_id', keepDeviceId);
      final count = result.length;
      LoggerService.info('Revoked ${count} devices', tag: 'Device');
      return count;
    } catch (e) {
      LoggerService.error('Bulk revocation failed', error: e, tag: 'Device');
      return 0;
    }
  }

  // ===== PUSH TOKEN =====

  /// Updates the push token for a device.
  Future<void> updatePushToken(String deviceId, String token) async {
    if (_client == null) return;
    try {
      await _client!.from('devices').update({
        'push_token': token,
      }).eq('device_id', deviceId);
    } catch (_) {}
  }

  // ===== CLEANUP =====

  /// Removes devices that haven't been seen in [maxAge].
  Future<int> cleanupStaleDevices({Duration maxAge = const Duration(days: 30)}) async {
    if (_client == null) return 0;
    try {
      final cutoff = DateTime.now().subtract(maxAge).toIso8601String();
      final result = await _client!
          .from('devices')
          .delete()
          .lt('last_seen_at', cutoff)
          .eq('status', 'revoked');
      return result.length;
    } catch (_) {
      return 0;
    }
  }
}

final deviceServiceProvider = Provider<DeviceService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return DeviceService(client);
});
