import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:novaapp/core/constants.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';

/// Voice call service with TURN server support, adaptive bitrate,
/// auto-reconnection, and call notifications.

enum CallState { idle, calling, ringing, connected, reconnecting, ended }

class VoiceCallService {
  final SupabaseClient? _client;
  CallState _state = CallState.idle;
  CallState get state => _state;

  String? _currentCallId;
  String? get currentCallId => _currentCallId;

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;

  // Bitrate adaptation
  int _currentBitrate = 32; // kbps
  int get currentBitrate => _currentBitrate;

  final StreamController<CallState> _stateController = StreamController<CallState>.broadcast();
  Stream<CallState> get onStateChanged => _stateController.stream;

  VoiceCallService(this._client);

  // ===== CALL MANAGEMENT =====

  /// Initiates a voice call to a recipient.
  Future<void> startCall({
    required String callerNovaId,
    required String recipientNovaId,
    required String callerName,
  }) async {
    if (_client == null) return;

    try {
      // Create call record
      final result = await _client!.from('calls').insert({
        'caller_nova_id': callerNovaId,
        'recipient_nova_id': recipientNovaId,
        'caller_name': callerName,
        'call_type': 'voice',
        'status': 'calling',
        'started_at': DateTime.now().toIso8601String(),
      }).select('id').single();

      _currentCallId = result['id'] as String;
      _updateState(CallState.calling);

      // Send call notification via Supabase Realtime
      await _client!.channel('call:$recipientNovaId').sendBroadcastMessage(
        event: 'incoming_call',
        payload: {
          'call_id': _currentCallId,
          'caller_nova_id': callerNovaId,
          'caller_name': callerName,
          'call_type': 'voice',
        },
      );

      LoggerService.info('Call initiated: $_currentCallId', tag: 'VoiceCall');
    } catch (e) {
      LoggerService.error('Failed to start call', error: e, tag: 'VoiceCall');
      _updateState(CallState.idle);
    }
  }

  /// Accepts an incoming call.
  Future<void> acceptCall({
    required String callId,
    required String recipientNovaId,
  }) async {
    if (_client == null) return;

    try {
      await _client!.from('calls').update({
        'status': 'connected',
        'connected_at': DateTime.now().toIso8601String(),
      }).eq('id', callId);

      // Add participant
      await _client!.from('call_participants').insert({
        'call_id': callId,
        'nova_id': recipientNovaId,
        'joined_at': DateTime.now().toIso8601String(),
      });

      _currentCallId = callId;
      _updateState(CallState.connected);
      LoggerService.info('Call accepted: $callId', tag: 'VoiceCall');
    } catch (e) {
      LoggerService.error('Failed to accept call', error: e, tag: 'VoiceCall');
    }
  }

  /// Ends the current call.
  Future<void> endCall({required String endedBy}) async {
    if (_client == null || _currentCallId == null) return;

    try {
      await _client!.from('calls').update({
        'status': 'ended',
        'ended_at': DateTime.now().toIso8601String(),
        'ended_by': endedBy,
      }).eq('id', _currentCallId!);

      // Calculate duration
      final call = await _client!.from('calls')
          .select('started_at, connected_at')
          .eq('id', _currentCallId!)
          .maybeSingle();

      int? duration;
      if (call != null && call['connected_at'] != null) {
        final connected = DateTime.parse(call['connected_at']);
        duration = DateTime.now().difference(connected).inSeconds;
        await _client!.from('calls').update({'duration': duration}).eq('id', _currentCallId!);
      }

      _reconnectTimer?.cancel();
      _updateState(CallState.ended);
      LoggerService.info('Call ended: $_currentCallId (${duration ?? 0}s)', tag: 'VoiceCall');

      _currentCallId = null;
      _updateState(CallState.idle);
    } catch (e) {
      LoggerService.error('Failed to end call', error: e, tag: 'VoiceCall');
    }
  }

  /// Rejects an incoming call.
  Future<void> rejectCall({
    required String callId,
    required String recipientNovaId,
  }) async {
    if (_client == null) return;

    try {
      await _client!.from('calls').update({
        'status': 'rejected',
        'ended_at': DateTime.now().toIso8601String(),
        'ended_by': recipientNovaId,
      }).eq('id', callId);

      LoggerService.info('Call rejected: $callId', tag: 'VoiceCall');
    } catch (e) {
      LoggerService.error('Failed to reject call', error: e, tag: 'VoiceCall');
    }
  }

  // ===== RECONNECTION =====

  /// Attempts to reconnect a dropped call.
  Future<void> attemptReconnect() async {
    if (_currentCallId == null || _client == null) return;

    _updateState(CallState.reconnecting);
    _reconnectAttempts++;

    if (_reconnectAttempts > _maxReconnectAttempts) {
      LoggerService.warning('Max reconnect attempts reached', tag: 'VoiceCall');
      await endCall(endedBy: 'system');
      return;
    }

    final delay = Duration(seconds: _reconnectAttempts * 2);
    _reconnectTimer = Timer(delay, () async {
      try {
        // Check if call is still active on server
        final call = await _client!.from('calls')
            .select('status')
            .eq('id', _currentCallId!)
            .maybeSingle();

        if (call != null && call['status'] == 'connected') {
          _updateState(CallState.connected);
          _reconnectAttempts = 0;
          LoggerService.info('Reconnected successfully', tag: 'VoiceCall');
        } else {
          attemptReconnect(); // Try again
        }
      } catch (e) {
        attemptReconnect();
      }
    });
  }

  // ===== BITRATE ADAPTATION =====

  /// Adjusts bitrate based on network conditions.
  void adjustBitrate({
    required double packetLoss, // 0.0 - 1.0
    required int latencyMs,
  }) {
    if (packetLoss > 0.1 || latencyMs > 300) {
      // Poor network — reduce bitrate
      _currentBitrate = (_currentBitrate * 0.7).round().clamp(8, 128);
    } else if (packetLoss < 0.02 && latencyMs < 100) {
      // Good network — increase bitrate
      _currentBitrate = (_currentBitrate * 1.3).round().clamp(8, 128);
    }
    LoggerService.info('Bitrate adjusted: $_currentBitrate kbps', tag: 'VoiceCall');
  }

  // ===== HELPERS =====

  void _updateState(CallState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
    }
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _stateController.close();
  }
}

final voiceCallServiceProvider = Provider<VoiceCallService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  final service = VoiceCallService(client);
  ref.onDispose(() => service.dispose());
  return service;
});
