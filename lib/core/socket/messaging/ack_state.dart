/// Delivery status model — SENT, DELIVERED and READ are DISTINCT states.
///
///   queued    — in the local outbox, not yet written to the socket
///   sent      — the SERVER acknowledged RECEIPT (message.ack). This means
///               "accepted & persisted by the server", nothing more.
///   delivered — the RECIPIENT'S DEVICE acknowledged receipt
///               (message.delivered, emitted by the recipient)
///   read      — the recipient READ the conversation (message.read)
///   failed    — terminal local failure (invalid envelope, retries exhausted)
///
/// `message.ack` is ONLY "the server got it". Treating it as "delivered"
/// would be a protocol bug — the statuses are never conflated.
enum MessageDeliveryStatus { queued, sent, delivered, read, failed }

/// Enforces forward-only status transitions:
///   queued -> sent -> delivered -> read
///   queued/sent -> failed
/// delivered/read can also arrive while still queued (server push order),
/// in which case sent is implied.
class AckStateMachine {
  /// Applies [next] to [current]; returns the merged status (never moves
  /// backwards).
  static MessageDeliveryStatus apply(
    MessageDeliveryStatus current,
    MessageDeliveryStatus next,
  ) {
    switch (next) {
      case MessageDeliveryStatus.queued:
        return current; // queued never overwrites anything
      case MessageDeliveryStatus.sent:
        return current == MessageDeliveryStatus.queued ||
                current == MessageDeliveryStatus.sent
            ? MessageDeliveryStatus.sent
            : current; // delivered/read already imply sent
      case MessageDeliveryStatus.delivered:
        return current == MessageDeliveryStatus.read
            ? MessageDeliveryStatus.read
            : MessageDeliveryStatus.delivered;
      case MessageDeliveryStatus.read:
        return MessageDeliveryStatus.read;
      case MessageDeliveryStatus.failed:
        return current == MessageDeliveryStatus.delivered ||
                current == MessageDeliveryStatus.read
            ? current // already past the point of failure
            : MessageDeliveryStatus.failed;
    }
  }
}
