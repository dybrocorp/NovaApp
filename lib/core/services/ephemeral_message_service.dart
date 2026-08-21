import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:novaapp/core/constants.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';

/// Ephemeral (disappearing) messages with configurable TTL.
///
/// After the recipient reads the message, it's automatically deleted
/// after [ttl] duration. Message is marked as ephemeral and a deletion
/// timer starts on the recipient's device.

class EphemeralMessageService {
  final SupabaseClient? _client;
  final Map<String, Timer> _timers = {};

  EphemeralMessageService(this._client);

  /// Predefined TTL options (in seconds).
  static const Map<String, int> ttlOptions = {
    '5s': 5,
    '30s': 30,
    '1m': 60,
    '5m': 300,
    '1h': 3600,
    '24h': 86400,
    '7d': 604800,
  };

  /// Sends an ephemeral message with the specified TTL.
  Future<bool> sendEphemeralMessage({
    required String chatId,
    required String senderId,
    required String text,
    required int ttlSeconds,
    String type = 'text',
  }) async {
    if (_client == null) return false;
    try {
      final expiresAt = DateTime.now().add(Duration(seconds: ttlSeconds));

      await _client!.from(AppConstants.tableMessages).insert({
        'chat_id': chatId,
        'sender_id': senderId,
        'text': text,
        'type': type,
        'is_ephemeral': true,
        'ephemeral_ttl': ttlSeconds,
        'ephemeral_expires_at': expiresAt.toIso8601String(),
        'timestamp': DateTime.now().toIso8601String(),
        'status': 'sent',
      });

      LoggerService.info('Ephemeral message sent (TTL: ${ttlSeconds}s)', tag: 'Ephemeral');
      return true;
    } catch (e) {
      LoggerService.error('Failed to send ephemeral message', error: e, tag: 'Ephemeral');
      return false;
    }
  }

  /// Starts a deletion timer for an ephemeral message.
  /// When the timer fires, the message content is wiped.
  void startDeletionTimer({
    required String messageId,
    required int ttlSeconds,
    required VoidCallback onExpired,
  }) {
    _timers[messageId]?.cancel();
    _timers[messageId] = Timer(Duration(seconds: ttlSeconds), () {
      _timers.remove(messageId);
      onExpired();
    });
  }

  /// Wipes the content of an expired ephemeral message.
  Future<void> wipeMessage(String messageId) async {
    if (_client == null) return;
    try {
      await _client!.from(AppConstants.tableMessages).update({
        'text': null,
        'is_deleted': true,
        'deleted_at': DateTime.now().toIso8601String(),
        'type': 'ephemeral_expired',
      }).eq('id', messageId);

      LoggerService.info('Ephemeral message wiped: $messageId', tag: 'Ephemeral');
    } catch (e) {
      LoggerService.error('Failed to wipe ephemeral message', error: e, tag: 'Ephemeral');
    }
  }

  /// Fetches ephemeral messages that have expired but not yet been wiped.
  Future<List<Map<String, dynamic>>> getExpiredMessages(String myNovaId) async {
    if (_client == null) return [];
    try {
      final now = DateTime.now().toIso8601String();
      final result = await _client!
          .from(AppConstants.tableMessages)
          .select('id, chat_id')
          .eq('is_ephemeral', true)
          .eq('is_deleted', false)
          .lt('ephemeral_expires_at', now)
          .neq('sender_id', myNovaId);

      return List<Map<String, dynamic>>.from(result);
    } catch (_) {
      return [];
    }
  }

  /// Cleans up all timers.
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }
}

final ephemeralMessageServiceProvider = Provider<EphemeralMessageService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return EphemeralMessageService(client);
});
