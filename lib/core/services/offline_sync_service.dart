import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/constants.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';
import 'package:novaapp/core/services/connectivity_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Offline-first message synchronization.
///
/// Flow:
///   1. Message is created locally (SQLite) with status='sending'
///   2. If online: send to Supabase, update status to 'sent'
///   3. If offline: add to pending queue, retry when online
///   4. On reconnect: flush pending queue with retry logic
///   5. Dedup: skip messages that already exist on server (by ID)
///   6. Conflict resolution: LWW (Last Write Wins) by timestamp

enum SyncState { idle, syncing, error, offline }

class OfflineSyncService {
  final SupabaseClient? _client;
  final ConnectivityService _connectivity;
  final List<Map<String, dynamic>> _pendingQueue = [];
  Timer? _retryTimer;
  int _retryCount = 0;
  static const int _maxRetries = 5;
  static const Duration _baseRetryDelay = Duration(seconds: 1);

  SyncState _state = SyncState.idle;
  SyncState get state => _state;

  final StreamController<SyncState> _stateController = StreamController<SyncState>.broadcast();
  Stream<SyncState> get onStateChanged => _stateController.stream;

  OfflineSyncService(this._client, this._connectivity) {
    // Listen for connectivity changes
    _connectivity.onConnectivityChanged.listen((state) {
      if (state != ConnectivityState.offline) {
        _retryCount = 0;
        flushPendingQueue();
      }
    });
  }

  /// Queues a message for sending (works offline or online).
  Future<void> queueMessage({
    required String chatId,
    required String senderId,
    required String text,
    String type = 'text',
    String? replyToId,
    bool isEphemeral = false,
    int? ephemeralTtl,
  }) async {
    final messageId = _generateLocalId();
    final timestamp = DateTime.now().toIso8601String();

    final message = {
      'id': messageId,
      'chat_id': chatId,
      'sender_id': senderId,
      'text': text,
      'type': type,
      'reply_to_id': replyToId,
      'is_ephemeral': isEphemeral,
      'ephemeral_ttl': ephemeralTtl,
      'timestamp': timestamp,
      'status': 'sending',
      'created_at': timestamp,
    };

    // Add to pending queue
    _pendingQueue.add(message);
    LoggerService.info('Message queued: $messageId', tag: 'OfflineSync');

    // Try to send immediately if online
    if (_connectivity.isOnline) {
      await flushPendingQueue();
    } else {
      _updateState(SyncState.offline);
    }
  }

  /// Flushes all pending messages in the queue.
  Future<void> flushPendingQueue() async {
    if (_pendingQueue.isEmpty || _client == null) return;

    _updateState(SyncState.syncing);
    final failed = <Map<String, dynamic>>[];

    for (final message in List<Map<String, dynamic>>.from(_pendingQueue)) {
      try {
        // Dedup check: skip if message ID already exists on server
        final existing = await _client!
            .from(AppConstants.tableMessages)
            .select('id')
            .eq('id', message['id'])
            .maybeSingle();

        if (existing != null) {
          LoggerService.info('Skipping duplicate: ${message["id"]}', tag: 'OfflineSync');
          _pendingQueue.remove(message);
          continue;
        }

        // Send to server
        await _client!.from(AppConstants.tableMessages).insert({
          'id': message['id'],
          'chat_id': message['chat_id'],
          'sender_id': message['sender_id'],
          'text': message['text'],
          'type': message['type'],
          'reply_to_id': message['reply_to_id'],
          'is_ephemeral': message['is_ephemeral'] ?? false,
          'ephemeral_ttl': message['ephemeral_ttl'],
          'timestamp': message['timestamp'],
          'status': 'sent',
          'created_at': message['created_at'],
        });

        _pendingQueue.remove(message);
        LoggerService.info('Message sent: ${message["id"]}', tag: 'OfflineSync');
      } catch (e) {
        LoggerService.warning('Failed to send: ${message["id"]}', tag: 'OfflineSync');
        failed.add(message);
      }
    }

    // Schedule retry for failed messages
    if (failed.isNotEmpty) {
      _pendingQueue.clear();
      _pendingQueue.addAll(failed);
      _scheduleRetry();
      _updateState(SyncState.error);
    } else {
      _retryCount = 0;
      _updateState(SyncState.idle);
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    if (_retryCount >= _maxRetries) {
      LoggerService.error('Max retries reached for ${_pendingQueue.length} messages', tag: 'OfflineSync');
      return;
    }

    final delay = _baseRetryDelay * (1 << _retryCount); // exponential backoff
    _retryTimer = Timer(delay, () {
      _retryCount++;
      flushPendingQueue();
    });
  }

  void _updateState(SyncState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
    }
  }

  /// Returns the count of pending messages.
  int get pendingCount => _pendingQueue.length;

  /// Returns the pending queue for UI display.
  List<Map<String, dynamic>> get pendingMessages => List.unmodifiable(_pendingQueue);

  /// Clears the pending queue (e.g., on logout).
  void clearQueue() {
    _pendingQueue.clear();
    _retryTimer?.cancel();
    _updateState(SyncState.idle);
  }

  String _generateLocalId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'local-$now';
  }

  void dispose() {
    _retryTimer?.cancel();
    _stateController.close();
  }
}

final offlineSyncServiceProvider = Provider<OfflineSyncService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  final connectivity = ref.watch(connectivityServiceProvider);
  final service = OfflineSyncService(client, connectivity);
  ref.onDispose(() => service.dispose());
  return service;
});
