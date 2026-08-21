import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:novaapp/core/constants.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';

/// Typing indicator service via Supabase Realtime.
///
/// Broadcasts typing state in real-time:
///   - When user starts typing → broadcast "typing" event
///   - After 3 seconds of inactivity → broadcast "stopped" event
///   - Other participants receive and display indicator

class TypingIndicatorService {
  final SupabaseClient? _client;
  RealtimeChannel? _typingChannel;
  Timer? _typingTimer;

  TypingIndicatorService(this._client);

  /// Joins a typing channel for a specific chat.
  void joinChat({
    required String chatId,
    required String myNovaId,
    required void Function(String userId, bool isTyping) onTypingChanged,
  }) {
    if (_client == null) return;

    _typingChannel = _client!.channel('typing:$chatId')
        .onBroadcast(
          event: 'typing',
          callback: (payload) {
            final userId = payload['user_id'] as String?;
            final isTyping = payload['is_typing'] as bool? ?? false;
            if (userId != null && userId != myNovaId) {
              onTypingChanged(userId, isTyping);
            }
          },
        )
        .subscribe();

    LoggerService.info('Joined typing channel: $chatId', tag: 'Typing');
  }

  /// Broadcasts that the user is typing.
  /// Auto-stops after [timeout] of inactivity.
  void startTyping({
    required String chatId,
    required String myNovaId,
    Duration timeout = const Duration(seconds: 3),
  }) {
    if (_typingChannel == null) return;

    _typingChannel!.sendBroadcastMessage(
      event: 'typing',
      payload: {'user_id': myNovaId, 'is_typing': true},
    );

    // Auto-stop after timeout
    _typingTimer?.cancel();
    _typingTimer = Timer(timeout, () {
      stopTyping(chatId: chatId, myNovaId: myNovaId);
    });
  }

  /// Broadcasts that the user stopped typing.
  void stopTyping({
    required String chatId,
    required String myNovaId,
  }) {
    if (_typingChannel == null) return;

    _typingTimer?.cancel();

    _typingChannel!.sendBroadcastMessage(
      event: 'typing',
      payload: {'user_id': myNovaId, 'is_typing': false},
    );
  }

  /// Leaves the typing channel.
  void leaveChat() {
    _typingTimer?.cancel();
    _typingChannel?.unsubscribe();
    _typingChannel = null;
  }

  /// Disposes resources.
  void dispose() {
    leaveChat();
  }
}

final typingIndicatorServiceProvider = Provider<TypingIndicatorService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return TypingIndicatorService(client);
});
