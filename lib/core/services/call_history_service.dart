import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:novaapp/core/constants.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';

/// Call history service for FASE 9.
///
/// Tracks all voice/video calls with:
///   - Direction (incoming/outgoing/missed)
///   - Duration
///   - Status (completed/rejected/missed)
///   - Timestamp

class CallHistoryService {
  final SupabaseClient? _client;

  CallHistoryService(this._client);

  /// Fetches call history for a user.
  /// Returns calls ordered by timestamp (newest first).
  Future<List<Map<String, dynamic>>> getCallHistory({
    required String novaId,
    int limit = 50,
    int offset = 0,
  }) async {
    if (_client == null) return [];
    try {
      final result = await _client!.from('calls').select('''
        id, caller_nova_id, recipient_nova_id, caller_name,
        call_type, status, duration, started_at, connected_at,
        ended_at, ended_by
      ''')
          .or('caller_nova_id.eq.$novaId,recipient_nova_id.eq.$novaId')
          .order('started_at', ascending: false)
          .range(offset, offset + limit - 1);

      return List<Map<String, dynamic>>.from(result);
    } catch (e) {
      LoggerService.error('Failed to fetch call history', error: e, tag: 'CallHistory');
      return [];
    }
  }

  /// Fetches call history with a specific contact.
  Future<List<Map<String, dynamic>>> getCallHistoryWith({
    required String myNovaId,
    required String contactNovaId,
    int limit = 20,
  }) async {
    if (_client == null) return [];
    try {
      final result = await _client!.from('calls').select('''
        id, caller_nova_id, recipient_nova_id, caller_name,
        call_type, status, duration, started_at, connected_at,
        ended_at, ended_by
      ''')
          .or(
            'and(caller_nova_id.eq.$myNovaId,recipient_nova_id.eq.$contactNovaId),'
            'and(caller_nova_id.eq.$contactNovaId,recipient_nova_id.eq.$myNovaId)',
          )
          .order('started_at', ascending: false)
          .limit(limit);

      return List<Map<String, dynamic>>.from(result);
    } catch (e) {
      LoggerService.error('Failed to fetch call history with contact', error: e, tag: 'CallHistory');
      return [];
    }
  }

  /// Gets the direction of a call relative to a user.
  static String getDirection(Map<String, dynamic> call, String myNovaId) {
    if (call['caller_nova_id'] == myNovaId) return 'outgoing';
    return 'incoming';
  }

  /// Gets the call status label.
  static String getStatusLabel(Map<String, dynamic> call, String myNovaId) {
    final status = call['status'] as String;
    if (status == 'missed') return 'Perdida';
    if (status == 'rejected') return 'Rechazada';
    if (status == 'ended') {
      final duration = call['duration'] as int?;
      if (duration == null || duration == 0) return 'Sin conexion';
      return _formatDuration(duration);
    }
    return status;
  }

  /// Formats duration in seconds to mm:ss or hh:mm:ss.
  static String _formatDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    if (minutes < 60) return '${minutes}m ${secs}s';
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    return '${hours}h ${mins}m';
  }

  /// Deletes a call from history.
  Future<bool> deleteCall(String callId) async {
    if (_client == null) return false;
    try {
      await _client!.from('calls').delete().eq('id', callId);
      return true;
    } catch (e) {
      LoggerService.error('Failed to delete call', error: e, tag: 'CallHistory');
      return false;
    }
  }

  /// Clears all call history for a user.
  Future<void> clearHistory(String novaId) async {
    if (_client == null) return;
    try {
      await _client!.from('calls').delete()
        .or('caller_nova_id.eq.$novaId,recipient_nova_id.eq.$novaId');
    } catch (e) {
      LoggerService.error('Failed to clear call history', error: e, tag: 'CallHistory');
    }
  }
}

final callHistoryServiceProvider = Provider<CallHistoryService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return CallHistoryService(client);
});
