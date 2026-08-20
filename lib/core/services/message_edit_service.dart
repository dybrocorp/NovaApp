import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:novaapp/core/constants.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';

/// Message editing and deletion service.
///
/// Edit: replaces text, marks as edited, preserves original timestamp.
/// Delete: soft delete (marks as deleted, content removed server-side).
/// Both operations are restricted to the message sender.

class MessageEditService {
  final SupabaseClient? _client;

  MessageEditService(this._client);

  /// Edits a message's text content.
  /// Only the original sender can edit.
  /// Returns true on success.
  Future<bool> editMessage({
    required String messageId,
    required String senderNovaId,
    required String newText,
  }) async {
    if (_client == null || newText.trim().isEmpty) return false;
    try {
      await _client!.from(AppConstants.tableMessages).update({
        'text': newText.trim(),
        'is_edited': true,
        'edited_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', messageId).eq('sender_id', senderNovaId);

      LoggerService.info('Message edited: $messageId', tag: 'MsgEdit');
      return true;
    } catch (e) {
      LoggerService.error('Failed to edit message', error: e, tag: 'MsgEdit');
      return false;
    }
  }

  /// Soft-deletes a message. Content is replaced with placeholder.
  /// Only the original sender can delete.
  /// Returns true on success.
  Future<bool> deleteMessage({
    required String messageId,
    required String senderNovaId,
  }) async {
    if (_client == null) return false;
    try {
      await _client!.from(AppConstants.tableMessages).update({
        'text': null,
        'is_deleted': true,
        'deleted_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
        'type': 'deleted',
      }).eq('id', messageId).eq('sender_id', senderNovaId);

      LoggerService.info('Message deleted: $messageId', tag: 'MsgEdit');
      return true;
    } catch (e) {
      LoggerService.error('Failed to delete message', error: e, tag: 'MsgEdit');
      return false;
    }
  }

  /// Returns true if the message can be edited (within 15 minutes).
  bool canEditMessage(Map<String, dynamic> message, String myNovaId) {
    if (message['sender_id'] != myNovaId) return false;
    if (message['is_deleted'] == true) return false;
    if (message['type'] == 'deleted') return false;

    final createdAt = DateTime.parse(message['created_at'] as String);
    return DateTime.now().difference(createdAt).inMinutes < 15;
  }

  /// Returns true if the message can be deleted (within 24 hours).
  bool canDeleteMessage(Map<String, dynamic> message, String myNovaId) {
    if (message['sender_id'] != myNovaId) return false;
    if (message['is_deleted'] == true) return false;
    if (message['type'] == 'deleted') return false;

    final createdAt = DateTime.parse(message['created_at'] as String);
    return DateTime.now().difference(createdAt).inHours < 24;
  }
}

final messageEditServiceProvider = Provider<MessageEditService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return MessageEditService(client);
});
