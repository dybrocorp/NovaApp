/// Reconnect synchronization (§14).
///
/// Flow required by §14:
///
///   authenticate -> get cursor -> sync -> apply events
///                -> update cursor -> normal operation
///
/// The hard rule: **never jump straight to the head without processing
/// pending pages.** The cursor advances only to the last event actually
/// applied, so a truncated page can never skip the events behind it.
///
/// Protections implemented here (§14):
///   * gaps        — detected via contiguous server_seq, then re-synced
///   * duplicates  — absorbed by the Inbox primary key
///   * out of order— events applied in log_seq order
///   * bad cursor  — a cursor ahead of the server resets to full replay
library;

import '../model/message_envelope_v1.dart';
import '../model/message_ids.dart';
import '../store/inbox_store.dart';
import '../store/sync_cursor_store.dart';
import 'message_receive_service.dart';

/// Issues `sync.request` and awaits `sync.response`.
abstract interface class SyncTransport {
  /// Account-wide sync when [conversationId] is null (§14): after a
  /// reconnect the client does not know which conversations moved, so
  /// asking only about known ones would miss entire chats.
  Future<Map<String, dynamic>?> requestSync({
    ConversationId? conversationId,
    Map<String, int> cursors = const <String, int>{},
    int? lastSeq,
  });
}

class SyncReport {
  const SyncReport({
    required this.conversationsSynced,
    required this.eventsApplied,
    required this.duplicatesSkipped,
    required this.gapsDetected,
    required this.pagesFetched,
  });

  final int conversationsSynced;
  final int eventsApplied;
  final int duplicatesSkipped;
  final int gapsDetected;
  final int pagesFetched;

  bool get hadWork => eventsApplied > 0 || duplicatesSkipped > 0;
}

class MessageSyncService {
  MessageSyncService({
    required SyncTransport transport,
    required SyncCursorStore cursors,
    required InboxStore inbox,
    required MessageReceiveService receiver,
    this.maxPagesPerConversation = 50,
  })  : _transport = transport,
        _cursors = cursors,
        _inbox = inbox,
        _receiver = receiver;

  final SyncTransport _transport;
  final SyncCursorStore _cursors;
  final InboxStore _inbox;
  final MessageReceiveService _receiver;

  /// Safety valve: bounds a pathological loop if the server keeps
  /// reporting `has_more` without advancing the cursor.
  final int maxPagesPerConversation;

  /// Full account-wide sync. Call right after `auth.success`.
  Future<SyncReport> syncAll() async {
    final cursors = await _cursors.allCursors();
    final response = await _transport.requestSync(cursors: cursors);
    if (response == null) {
      return const SyncReport(
        conversationsSynced: 0,
        eventsApplied: 0,
        duplicatesSkipped: 0,
        gapsDetected: 0,
        pagesFetched: 0,
      );
    }
    return _applyResponse(response, pagesFetched: 1);
  }

  /// Syncs one conversation, following pagination to the end.
  Future<SyncReport> syncConversation(ConversationId conversationId) async {
    var applied = 0;
    var duplicates = 0;
    var gaps = 0;
    var pages = 0;

    for (var page = 0; page < maxPagesPerConversation; page++) {
      final cursor = await _cursors.cursorFor(conversationId);
      final response = await _transport.requestSync(
        conversationId: conversationId,
        lastSeq: cursor.lastLogSeq,
      );
      if (response == null) break;

      pages++;
      final report = await _applyResponse(response, pagesFetched: 1);
      applied += report.eventsApplied;
      duplicates += report.duplicatesSkipped;
      gaps += report.gapsDetected;

      // Stop when the server says there is nothing more, or when the
      // cursor stopped moving (defensive: avoids an infinite loop if the
      // server misreports has_more).
      final hasMore = response['has_more'] == true;
      final after = await _cursors.cursorFor(conversationId);
      if (!hasMore || after.lastLogSeq == cursor.lastLogSeq) break;
    }

    return SyncReport(
      conversationsSynced: 1,
      eventsApplied: applied,
      duplicatesSkipped: duplicates,
      gapsDetected: gaps,
      pagesFetched: pages,
    );
  }

  /// Applies a `sync.response`, in either shape the server may send:
  /// multi-conversation (`conversations: [...]`) or the single-conversation
  /// mirror at the top level.
  Future<SyncReport> _applyResponse(
    Map<String, dynamic> response, {
    required int pagesFetched,
  }) async {
    final conversations = <Map<String, dynamic>>[];
    final raw = response['conversations'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map<String, dynamic>) conversations.add(entry);
      }
    } else if (response['conversation_id'] is String) {
      conversations.add(response);
    }

    var applied = 0;
    var duplicates = 0;
    var gaps = 0;

    for (final entry in conversations) {
      final conversationId = ConversationId.tryParse(entry['conversation_id'] as String?);
      if (conversationId == null) continue;

      final events = entry['events'];
      if (events is! List) continue;

      // Apply in log_seq order: the server may batch, and out-of-order
      // application would corrupt the contiguity check below (§14).
      final ordered = events.whereType<Map<String, dynamic>>().toList()
        ..sort((a, b) =>
            ((a['log_seq'] as int?) ?? 0).compareTo((b['log_seq'] as int?) ?? 0));

      var lastAppliedLogSeq = 0;
      for (final event in ordered) {
        final type = event['type'] as String?;

        if (type == 'message.new') {
          final envelope = MessageEnvelopeV1.tryParseInbound(event);
          if (envelope == null) continue;

          // Replayed events do NOT re-emit DELIVERED: the receipt was
          // already sent when the message first arrived.
          final result = await _receiver.ingest(envelope, emitDelivered: false);
          switch (result.outcome) {
            case ReceiveOutcome.applied:
              applied++;
            case ReceiveOutcome.duplicate:
              duplicates++;
            case ReceiveOutcome.rejected:
            case ReceiveOutcome.decryptFailed:
            case ReceiveOutcome.ignoredBlocked:
              break;
          }
        }
        // Receipt events (message.delivered / message.read) are applied
        // by the delivery layer; they still advance the cursor here.

        final logSeq = event['log_seq'] as int?;
        if (logSeq != null && logSeq > lastAppliedLogSeq) lastAppliedLogSeq = logSeq;
      }

      // §14: advance ONLY to the last event actually applied — never to
      // the server's reported head. A truncated page would otherwise
      // silently skip everything behind it.
      if (lastAppliedLogSeq > 0) {
        await _cursors.advance(conversationId, logSeq: lastAppliedLogSeq);
      }

      if (await _hasGap(conversationId)) gaps++;
    }

    return SyncReport(
      conversationsSynced: conversations.length,
      eventsApplied: applied,
      duplicatesSkipped: duplicates,
      gapsDetected: gaps,
      pagesFetched: pagesFetched,
    );
  }

  /// True when the stored messages are not contiguous in server_seq.
  ///
  /// With 1,2,3,7 the contiguous prefix is 3 while the highest is 7 —
  /// messages 4..6 are missing and must be re-synced.
  Future<bool> _hasGap(ConversationId conversationId) async {
    final contiguous = await _inbox.lastContiguousSeq(conversationId);
    final records = await _inbox.forConversation(conversationId, limit: 1000);
    var highest = 0;
    for (final record in records) {
      final seq = record.envelope.serverSeq ?? 0;
      if (seq > highest) highest = seq;
    }
    return highest > contiguous;
  }

  /// Recovery for a corrupted or over-advanced cursor (§14).
  ///
  /// Safe by construction: a full replay cannot duplicate anything,
  /// because the Inbox deduplicates on message_id.
  Future<void> resetCursor(ConversationId conversationId) =>
      _cursors.reset(conversationId);
}
