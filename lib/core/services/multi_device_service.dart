import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:novaapp/core/constants.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';
import 'package:novaapp/core/services/device_service.dart';
import 'package:novaapp/core/services/session_service.dart';

/// Multi-device synchronization service for FASE 12.
///
/// Features:
///   - Device registration with approval flow
///   - Message sync across devices
///   - Contact sync
///   - Settings sync
///   - Remote device revocation
///   - Remote logout

class MultiDeviceService {
  final SupabaseClient? _client;
  final DeviceService _deviceService;
  final SessionService _sessionService;

  MultiDeviceService(this._client, this._deviceService, this._sessionService);

  // ===== DEVICE REGISTRATION =====

  /// Registers a new device and requests approval from existing devices.
  /// Returns a pending request ID.
  Future<String?> requestDeviceApproval({
    required String novaId,
    required String deviceId,
    required String deviceName,
    required String platform,
    required String osVersion,
    required String appVersion,
  }) async {
    if (_client == null) return null;
    try {
      // Create pending device request
      final result = await _client!.from('device_approvals').insert({
        'nova_id': novaId,
        'device_id': deviceId,
        'device_name': deviceName,
        'platform': platform,
        'os_version': osVersion,
        'app_version': appVersion,
        'status': 'pending',
        'requested_at': DateTime.now().toIso8601String(),
      }).select('id').single();

      final requestId = result['id'] as String;

      // Notify existing devices of the approval request
      await _notifyExistingDevices(
        novaId: novaId,
        event: 'device_approval_request',
        data: {
          'request_id': requestId,
          'device_name': deviceName,
          'platform': platform,
        },
      );

      LoggerService.info('Device approval requested: $requestId', tag: 'MultiDevice');
      return requestId;
    } catch (e) {
      LoggerService.error('Failed to request device approval', error: e, tag: 'MultiDevice');
      return null;
    }
  }

  /// Approves a device request (from an existing device).
  Future<bool> approveDevice({
    required String requestId,
    required String approverNovaId,
  }) async {
    if (_client == null) return false;
    try {
      // Update approval status
      await _client!.from('device_approvals').update({
        'status': 'approved',
        'approved_at': DateTime.now().toIso8601String(),
        'approved_by': approverNovaId,
      }).eq('id', requestId);

      // Get the approved device details
      final approval = await _client!.from('device_approvals')
          .select('device_id, nova_id, device_name, platform, os_version, app_version')
          .eq('id', requestId)
          .single();

      // Register the device
      await _deviceService.registerDevice(
        novaId: approval['nova_id'],
        deviceId: approval['device_id'],
        deviceName: approval['device_name'],
        platform: approval['platform'],
        osVersion: approval['os_version'],
        appVersion: approval['app_version'],
      );

      LoggerService.info('Device approved: ${approval["device_id"]}', tag: 'MultiDevice');
      return true;
    } catch (e) {
      LoggerService.error('Failed to approve device', error: e, tag: 'MultiDevice');
      return false;
    }
  }

  /// Rejects a device request.
  Future<bool> rejectDevice({
    required String requestId,
    required String rejecterNovaId,
  }) async {
    if (_client == null) return false;
    try {
      await _client!.from('device_approvals').update({
        'status': 'rejected',
        'rejected_at': DateTime.now().toIso8601String(),
        'rejected_by': rejecterNovaId,
      }).eq('id', requestId);

      LoggerService.info('Device rejected: $requestId', tag: 'MultiDevice');
      return true;
    } catch (e) {
      LoggerService.error('Failed to reject device', error: e, tag: 'MultiDevice');
      return false;
    }
  }

  // ===== SYNC =====

  /// Syncs messages from server to local database.
  /// Returns the number of new messages synced.
  Future<int> syncMessages({
    required String novaId,
    required DateTime lastSyncTime,
  }) async {
    if (_client == null) return 0;
    try {
      final result = await _client!.from(AppConstants.tableMessages).select('*')
          .or('chat_id.like.%$novaId%,sender_id.eq.$novaId')
          .gt('created_at', lastSyncTime.toIso8601String())
          .order('created_at');

      final messages = List<Map<String, dynamic>>.from(result);
      LoggerService.info('Synced ${messages.length} messages', tag: 'MultiDevice');
      return messages.length;
    } catch (e) {
      LoggerService.error('Failed to sync messages', error: e, tag: 'MultiDevice');
      return 0;
    }
  }

  /// Syncs contacts from server.
  Future<List<Map<String, dynamic>>> syncContacts(String novaId) async {
    if (_client == null) return [];
    try {
      final result = await _client!.from('contacts').select('*')
          .eq('user_nova_id', novaId)
          .order('updated_at', ascending: false);

      LoggerService.info('Synced ${result.length} contacts', tag: 'MultiDevice');
      return List<Map<String, dynamic>>.from(result);
    } catch (e) {
      LoggerService.error('Failed to sync contacts', error: e, tag: 'MultiDevice');
      return [];
    }
  }

  /// Syncs user settings.
  Future<Map<String, dynamic>?> syncSettings(String novaId) async {
    if (_client == null) return null;
    try {
      final result = await _client!.from('user_settings')
          .select('*')
          .eq('nova_id', novaId)
          .maybeSingle();
      return result;
    } catch (e) {
      LoggerService.error('Failed to sync settings', error: e, tag: 'MultiDevice');
      return null;
    }
  }

  // ===== REMOTE ACTIONS =====

  /// Revokes a specific device remotely.
  Future<bool> revokeDeviceRemote({
    required String novaId,
    required String targetDeviceId,
    required String requesterDeviceId,
  }) async {
    if (_client == null) return false;
    try {
      // Verify requester is an active device
      final requester = await _client!.from('devices')
          .select('device_id')
          .eq('device_id', requesterDeviceId)
          .eq('nova_id', novaId)
          .eq('status', 'active')
          .maybeSingle();

      if (requester == null) return false;

      // Revoke the target device
      await _deviceService.revokeDevice(targetDeviceId);

      // Also revoke all sessions for that device
      await _sessionService.revokeSession(targetDeviceId);

      LoggerService.info('Device revoked remotely: $targetDeviceId', tag: 'MultiDevice');
      return true;
    } catch (e) {
      LoggerService.error('Failed to revoke device remotely', error: e, tag: 'MultiDevice');
      return false;
    }
  }

  /// Logs out all devices except the current one.
  Future<int> logoutAllDevices({
    required String novaId,
    required String keepDeviceId,
  }) async {
    if (_client == null) return 0;
    try {
      // Revoke all devices except current
      final deviceCount = await _deviceService.revokeAllExcept(novaId, keepDeviceId);

      // Revoke all sessions except current
      await _sessionService.revokeAllExcept(novaId, keepDeviceId);

      LoggerService.info('Logged out from $deviceCount devices', tag: 'MultiDevice');
      return deviceCount;
    } catch (e) {
      LoggerService.error('Failed to logout all devices', error: e, tag: 'MultiDevice');
      return 0;
    }
  }

  // ===== DEVICE LIST =====

  /// Returns all active devices for a Nova ID.
  Future<List<Map<String, dynamic>>> getActiveDevices(String novaId) async {
    return _deviceService.getDevices(novaId);
  }

  /// Returns pending device approval requests.
  Future<List<Map<String, dynamic>>> getPendingApprovals(String novaId) async {
    if (_client == null) return [];
    try {
      final result = await _client!.from('device_approvals')
          .select('*')
          .eq('nova_id', novaId)
          .eq('status', 'pending')
          .order('requested_at', ascending: false);
      return List<Map<String, dynamic>>.from(result);
    } catch (_) {
      return [];
    }
  }

  // ===== HELPERS =====

  /// Notifies existing devices of an event.
  Future<void> _notifyExistingDevices({
    required String novaId,
    required String event,
    required Map<String, dynamic> data,
  }) async {
    if (_client == null) return;
    try {
      await _client!.channel('device-events:$novaId').sendBroadcastMessage(
        event: event,
        payload: data,
      );
    } catch (_) {}
  }
}

final multiDeviceServiceProvider = Provider<MultiDeviceService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  final deviceService = ref.watch(deviceServiceProvider);
  final sessionService = ref.watch(sessionServiceProvider);
  return MultiDeviceService(client, deviceService, sessionService);
});
