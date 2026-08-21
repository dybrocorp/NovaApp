import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:novaapp/core/constants.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';

/// Message reactions service.
///
/// Users can react to messages with emojis.
/// Each user can have one reaction per message (multi-react not supported).
/// Reactions are stored in a separate table for efficient querying.

class ReactionService {
  final SupabaseClient? _client;

  ReactionService(this._client);

  /// Adds or updates a reaction on a message.
  Future<bool> addReaction({
    required String messageId,
    required String novaId,
    required String emoji,
  }) async {
    if (_client == null) return false;
    try {
      await _client!.from('message_reactions').upsert({
        'message_id': messageId,
        'nova_id': novaId,
        'emoji': emoji,
        'created_at': DateTime.now().toIso8601String(),
      }, onConflict: 'message_id,nova_id');

      LoggerService.info('Reaction added: $emoji on $messageId', tag: 'Reaction');
      return true;
    } catch (e) {
      LoggerService.error('Failed to add reaction', error: e, tag: 'Reaction');
      return false;
    }
  }

  /// Removes a reaction from a message.
  Future<bool> removeReaction({
    required String messageId,
    required String novaId,
  }) async {
    if (_client == null) return false;
    try {
      await _client!.from('message_reactions').delete()
        .eq('message_id', messageId)
        .eq('nova_id', novaId);

      LoggerService.info('Reaction removed from $messageId', tag: 'Reaction');
      return true;
    } catch (e) {
      LoggerService.error('Failed to remove reaction', error: e, tag: 'Reaction');
      return false;
    }
  }

  /// Toggles a reaction (add if not present, remove if same, replace if different).
  Future<void> toggleReaction({
    required String messageId,
    required String novaId,
    required String emoji,
  }) async {
    if (_client == null) return;
    try {
      final existing = await _client!
          .from('message_reactions')
          .select('emoji')
          .eq('message_id', messageId)
          .eq('nova_id', novaId)
          .maybeSingle();

      if (existing == null) {
        // No reaction yet — add
        await addReaction(messageId: messageId, novaId: novaId, emoji: emoji);
      } else if (existing['emoji'] == emoji) {
        // Same emoji — remove
        await removeReaction(messageId: messageId, novaId: novaId);
      } else {
        // Different emoji — replace
        await addReaction(messageId: messageId, novaId: novaId, emoji: emoji);
      }
    } catch (e) {
      LoggerService.error('Failed to toggle reaction', error: e, tag: 'Reaction');
    }
  }

  /// Fetches all reactions for a list of message IDs.
  /// Returns { messageId: { emoji: [novaId, ...] } }
  Future<Map<String, Map<String, List<String>>>> getReactions(
    List<String> messageIds,
  ) async {
    if (_client == null || messageIds.isEmpty) return {};
    try {
      final result = await _client!
          .from('message_reactions')
          .select('message_id, nova_id, emoji')
          .inFilter('message_id', messageIds);

      final reactions = <String, Map<String, List<String>>>{};
      for (final row in result) {
        final msgId = row['message_id'] as String;
        final emoji = row['emoji'] as String;
        final novaId = row['nova_id'] as String;

        reactions.putIfAbsent(msgId, () => {});
        reactions[msgId]!.putIfAbsent(emoji, () => []);
        reactions[msgId]![emoji]!.add(novaId);
      }

      return reactions;
    } catch (e) {
      LoggerService.error('Failed to fetch reactions', error: e, tag: 'Reaction');
      return {};
    }
  }

  /// Subscribes to reaction changes for a set of messages.
  void subscribeToReactions({
    required List<String> messageIds,
    required void Function(String messageId, String emoji, String novaId, bool added) onChanged,
  }) {
    if (_client == null || messageIds.isEmpty) return;

    _client!.channel('reactions:${messageIds.first}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'message_reactions',
          callback: (payload) {
            final record = payload.eventType == PostgresChangeEvent.delete
                ? payload.oldRecord
                : payload.newRecord;
            final msgId = record['message_id'] as String?;
            if (msgId != null && messageIds.contains(msgId)) {
              onChanged(
                msgId,
                record['emoji'] as String? ?? '',
                record['nova_id'] as String? ?? '',
                payload.eventType != PostgresChangeEvent.delete,
              );
            }
          },
        )
        .subscribe();
  }
}

final reactionServiceProvider = Provider<ReactionService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return ReactionService(client);
});
