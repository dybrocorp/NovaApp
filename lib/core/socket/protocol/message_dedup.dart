/// REFERENCE implementation of server-side message deduplication
/// (idempotency by message_id) plus the client-side mirror used by the
/// outbox when retrying after a reconnection.
///
/// Idempotency rule: a `message.send` carrying a message_id that was already
/// accepted is NOT re-persisted and NOT re-fanned-out; the server answers
/// with the ORIGINAL ack (same server_seq) so the retrying client converges.
class MessageDedup {
  MessageDedup({this.windowSize = 4096});

  /// Number of recent ids remembered (LRU). Production mapping: Redis SET
  /// with TTL per account/device.
  final int windowSize;

  final Map<String, int> _seen = <String, int>{};
  int _clockTick = 0;

  /// Returns true if [messageId] is new (and remembers it).
  /// Returns false for a duplicate.
  bool accept(String messageId) {
    if (_seen.containsKey(messageId)) {
      _seen[messageId] = _clockTick++;
      return false;
    }
    _seen[messageId] = _clockTick++;
    if (_seen.length > windowSize) {
      _evictOldest();
    }
    return true;
  }

  /// True when the id is already known (without consuming).
  bool contains(String messageId) => _seen.containsKey(messageId);

  void _evictOldest() {
    String? oldest;
    var oldestTick = 1 << 62;
    for (final entry in _seen.entries) {
      if (entry.value < oldestTick) {
        oldestTick = entry.value;
        oldest = entry.key;
      }
    }
    if (oldest != null) _seen.remove(oldest);
  }

  int get remembered => _seen.length;
}
