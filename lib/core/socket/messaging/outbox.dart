import 'ack_state.dart';
import 'message_envelope.dart';

/// Idempotent outgoing-message queue.
///
/// Purpose: survive reconnections without duplicating messages.
///   * Every send gets a stable message_id at creation time.
///   * The envelope stays in the outbox until the server `message.ack`s it.
///   * On reconnection + re-authentication, un-acked envelopes are RE-EMITTED
///     WITH THE SAME message_id — the server deduplicates by id
///     (see MessageDedup), so the message is persisted exactly once.
///   * Retries are bounded by [maxAge]; older unsent envelopes fail locally.
///
/// Only metadata lives here (ids, statuses, timestamps); ciphertext blobs are
/// referenced by the envelope itself and never logged.
class OutboxQueue {
  OutboxQueue({
    this.maxAge = const Duration(minutes: 10),
    this.maxEntries = 500,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration maxAge;
  final int maxEntries;
  final DateTime Function() _clock;

  final Map<String, OutboxEntry> _entries = <String, OutboxEntry>{};

  int get length => _entries.length;

  /// Enqueues an envelope. Adding the same message_id twice is a no-op
  /// (client-side dedup safety net).
  OutboxEntry enqueue(MessageEnvelope envelope) {
    final existing = _entries[envelope.messageId];
    if (existing != null) return existing;
    final entry = OutboxEntry(
      envelope: envelope,
      status: MessageDeliveryStatus.queued,
      enqueuedAt: _clock(),
      lastAttemptAt: null,
    );
    _entries[envelope.messageId] = entry;
    if (_entries.length > maxEntries) {
      _evictOldestQueued();
    }
    return entry;
  }

  /// Marks an entry as server-acknowledged (SENT — not delivered).
  void markAcked(String messageId) {
    final entry = _entries[messageId];
    if (entry == null) return;
    _entries[messageId] = entry.copyWith(
      status: AckStateMachine.apply(entry.status, MessageDeliveryStatus.sent),
    );
  }

  /// Records a send attempt timestamp (for retries/metrics).
  void markAttempted(String messageId, DateTime at) {
    final entry = _entries[messageId];
    if (entry == null) return;
    _entries[messageId] = entry.markAttempt(at);
  }

  /// Applies a delivery-status update (delivered/read arrive from the
  /// recipient via the server).
  void markStatus(String messageId, MessageDeliveryStatus status) {
    final entry = _entries[messageId];
    if (entry == null) return;
    _entries[messageId] = entry.copyWith(
      status: AckStateMachine.apply(entry.status, status),
    );
  }

  /// Marks an entry terminally failed.
  void markFailed(String messageId) {
    final entry = _entries[messageId];
    if (entry == null) return;
    _entries[messageId] = entry.copyWith(
      status: AckStateMachine.apply(entry.status, MessageDeliveryStatus.failed),
    );
  }

  /// Entries that should be (re)sent now: queued or timed-out, not too old.
  List<OutboxEntry> dueEntries() {
    final now = _clock();
    final due = <OutboxEntry>[];
    for (final entry in _entries.values) {
      if (entry.status != MessageDeliveryStatus.queued) continue;
      if (now.difference(entry.enqueuedAt) > maxAge) {
        _entries[entry.envelope.messageId] = entry.copyWith(
          status: MessageDeliveryStatus.failed,
        );
        continue;
      }
      due.add(entry);
    }
    return due;
  }

  /// Removes terminal entries (acked + old, failed) to bound memory.
  /// Acked entries are kept briefly so late delivered/read updates match.
  void cleanup({Duration keepAckedFor = const Duration(minutes: 30)}) {
    final now = _clock();
    _entries.removeWhere((_, e) {
      if (e.status == MessageDeliveryStatus.failed) return true;
      if (e.status == MessageDeliveryStatus.queued) return false;
      return now.difference(e.enqueuedAt) > keepAckedFor;
    });
  }

  OutboxEntry? byMessageId(String messageId) => _entries[messageId];

  void clear() => _entries.clear();

  void _evictOldestQueued() {
    String? oldestId;
    DateTime? oldestAt;
    for (final entry in _entries.values) {
      if (entry.status != MessageDeliveryStatus.queued) continue;
      if (oldestAt == null || entry.enqueuedAt.isBefore(oldestAt)) {
        oldestAt = entry.enqueuedAt;
        oldestId = entry.envelope.messageId;
      }
    }
    if (oldestId != null) {
      final entry = _entries[oldestId]!;
      _entries[oldestId] = entry.copyWith(
        status: MessageDeliveryStatus.failed,
      );
    }
  }
}

class OutboxEntry {
  const OutboxEntry({
    required this.envelope,
    required this.status,
    required this.enqueuedAt,
    required this.lastAttemptAt,
  });

  final MessageEnvelope envelope;
  final MessageDeliveryStatus status;
  final DateTime enqueuedAt;
  final DateTime? lastAttemptAt;

  OutboxEntry copyWith({
    MessageDeliveryStatus? status,
    DateTime? lastAttemptAt,
  }) =>
      OutboxEntry(
        envelope: envelope,
        status: status ?? this.status,
        enqueuedAt: enqueuedAt,
        lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      );

  OutboxEntry markAttempt(DateTime at) => OutboxEntry(
        envelope: envelope,
        status: status,
        enqueuedAt: enqueuedAt,
        lastAttemptAt: at,
      );
}
