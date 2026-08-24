/// Per-conversation sequence gap detection.
///
/// Ordering rules (see docs/SOCKET_ARCHITECTURE.md):
///   * The server assigns a MONOTONIC `server_seq` per conversation.
///   * Client timestamps are hints for UI only — never ordering authority.
///   * Duplicates (same message_id seen twice, e.g. after a resync) are
///     dropped, not re-applied.
///   * A gap (seq 5,6,8) means messages 7 are MISSING -> the client must
///     request a resync (sync.request with last contiguous cursor).
///   * E2EE ciphertext is NEVER modified or reordered semantically: the
///     detector only tracks transport-level ordering; decryption order is
///     handled by the ratchet layer per message.
class SequenceGapDetector {
  final Map<String, int> _lastContiguousSeq = <String, int>{};
  final Map<String, Set<int>> _bufferedSeqs = <String, Set<int>>{};
  final Map<String, Set<String>> _seenMessageIds = <String, Set<String>>{};

  /// Outcome of feeding one inbound message.
  enum FeedResult {
    accepted,
    duplicate,
    buffered, // out of order, waiting for predecessors
    gapDetected, // accepted/buffered AND a hole appeared
  }

  /// Feeds an inbound message. The E2EE content is opaque here; only ids
  /// and sequence numbers are inspected.
  FeedResult feed({
    required String conversationId,
    required String messageId,
    required int serverSeq,
  }) {
    final seen = _seenMessageIds.putIfAbsent(
      conversationId,
      () => <String>{},
    );
    if (!seen.add(messageId)) return FeedResult.duplicate;

    var buffered = false;
    var gap = false;
    final last = _lastContiguousSeq[conversationId] ?? 0;
    if (serverSeq == last + 1) {
      _lastContiguousSeq[conversationId] = serverSeq;
      gap = _drainBuffer(conversationId);
    } else if (serverSeq > last + 1) {
      _bufferedSeqs.putIfAbsent(conversationId, () => <int>{}).add(serverSeq);
      buffered = true;
      gap = true;
    }
    // serverSeq <= last: already covered by the contiguous cursor (stale
    // re-delivery); the id dedup above protects re-processing.
    if (gap) return FeedResult.gapDetected;
    if (buffered) return FeedResult.buffered;
    return FeedResult.accepted;
  }

  /// Last contiguous (no known holes) sequence for a conversation.
  /// Used as the `last_cursor` in sync.request.
  int lastContiguous(String conversationId) =>
      _lastContiguousSeq[conversationId] ?? 0;

  /// True when there are buffered out-of-order messages (a hole exists).
  bool hasPendingGap(String conversationId) =>
      (_bufferedSeqs[conversationId]?.isNotEmpty ?? false);

  /// After a successful resync the buffer is dropped and the cursor is
  /// authoritative from the server.
  void resynced(String conversationId, {required int newCursor}) {
    _bufferedSeqs.remove(conversationId);
    _lastContiguousSeq[conversationId] = newCursor;
  }

  /// Advances the contiguous cursor after draining buffered sequences.
  /// Returns true if a gap remains after draining.
  bool _drainBuffer(String conversationId) {
    final buffer = _bufferedSeqs[conversationId];
    if (buffer == null || buffer.isEmpty) return false;
    var cursor = _lastContiguousSeq[conversationId] ?? 0;
    while (buffer.contains(cursor + 1)) {
      cursor++;
      buffer.remove(cursor);
    }
    _lastContiguousSeq[conversationId] = cursor;
    return buffer.isNotEmpty;
  }
}
