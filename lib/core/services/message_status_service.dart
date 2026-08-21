import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:novaapp/core/constants.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';

/// Real message status states:
///   sending  → locally queued, not yet sent
///   sent     → server acknowledged receipt
///   delivered→ recipient's device downloaded
///   read     → recipient opened the conversation

enum MessageStatus {
  sending,
  sent,
  delivered,
  read,
}

/// Manages real message states via Supabase Realtime.
///
/// Status transitions are tracked server-side:
///   sender → server → recipient device acknowledges → server updates → sender sees update

class MessageStatusService {
  final SupabaseClient? _client;
  RealtimeChannel? _statusChannel;

  /// Map from status name string to enum value.
  static final Map<String, MessageStatus> _statusByName = {
    for (final s in MessageStatus.values) s.name: s,
  };

  MessageStatusService(this._client);

  /// Updates the status of a message on the server.
  Future<void> updateStatus({
    required String messageId,
    required MessageStatus status,
  }) async {
    if (_client == null) return;
    try {
      await _client!.from('messages').update({
        'status': status.name,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', messageId);
    } catch (e) {
      LoggerService.error('Failed to update message status', error: e, tag: 'MsgStatus');
    }
  }

  /// Marks all messages in a chat as read.
  Future<void> markChatAsRead({
    required String chatId,
    required String myNovaId,
  }) async {
    if (_client == null) return;
    try {
      await _client!.from('messages').update({
        'status': MessageStatus.read.name,
      }).eq('chat_id', chatId)
        .neq('sender_id', myNovaId)
        .neq('status', MessageStatus.read.name);
    } catch (e) {
      LoggerService.error('Failed to mark chat as read', error: e, tag: 'MsgStatus');
    }
  }

  /// Marks a single message as delivered (recipient's device received it).
  Future<void> markAsDelivered(String messageId) async {
    if (_client == null) return;
    try {
      await _client!.from('messages').update({
        'status': MessageStatus.delivered.name,
      }).eq('id', messageId)
        .inFilter('status', [MessageStatus.sent.name]);
    } catch (_) {}
  }

  /// Subscribes to status changes for messages I sent.
  /// Calls [onStatusChanged] when a status update is received.
  void subscribeToStatusChanges({
    required String myNovaId,
    required void Function(String messageId, MessageStatus newStatus) onStatusChanged,
  }) {
    if (_client == null) return;

    _statusChannel = _client!.channel('message-status:$myNovaId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: AppConstants.tableMessages,
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'sender_id',
            value: myNovaId,
          ),
          callback: (payload) {
            final newRecord = payload.newRecord;
            final messageId = newRecord['id'] as String?;
            final statusStr = newRecord['status'] as String?;
            if (messageId != null && statusStr != null) {
              final status = _statusByName[statusStr];
              if (status != null) {
                onStatusChanged(messageId, status);
              }
            }
          },
        )
        .subscribe();

    LoggerService.info('Subscribed to message status changes', tag: 'MsgStatus');
  }

  /// Unsubscribes from status changes.
  void unsubscribe() {
    _statusChannel?.unsubscribe();
    _statusChannel = null;
  }

  /// Fetches the latest status for a batch of message IDs.
  Future<Map<String, MessageStatus>> getStatuses(List<String> messageIds) async {
    if (_client == null || messageIds.isEmpty) return {};
    try {
      final result = await _client!
          .from('messages')
          .select('id, status')
          .inFilter('id', messageIds);

      return {
        for (final row in result)
          row['id'] as String: _statusByName[row['status'] as String] ?? MessageStatus.sent,
      };
    } catch (_) {
      return {};
    }
  }
}

final messageStatusServiceProvider = Provider<MessageStatusService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return MessageStatusService(client);
});
