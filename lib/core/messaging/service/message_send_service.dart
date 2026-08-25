/// Outgoing message pipeline (§10, §11, §12, §15, §29).
///
/// Implements the §10 flow exactly, and in this order:
///
///   user writes
///     -> create message_id            (stable across retries & devices)
///     -> block check                  (§29, before anything else)
///     -> resolve target devices       (§15/§16, active devices only)
///     -> Double Ratchet encrypt       (once per target device)
///     -> PERSIST to Outbox            (§11: never lose the message)
///     -> emit message.send            (only if connected)
///     -> message.ack -> mark SENT
///
/// The persist-before-transmit ordering is what makes §11 true: if the
/// process dies after step 5, the message is on disk and the flusher
/// retransmits it on restart. Transmitting first would open a window in
/// which a crash silently loses a message the user believes was sent.
library;

import '../../services/double_ratchet_service.dart';
import '../crypto/message_encryption_service.dart';
import '../model/delivery_state.dart';
import '../model/message_body.dart';
import '../model/message_envelope_v1.dart';
import '../model/message_ids.dart';
import '../store/outbox_store.dart';
import 'conversation_service.dart';

/// Transport abstraction. Implemented over `WebSocketService` in the app;
/// injected here so the engine is testable without a socket.
abstract interface class MessageTransport {
  bool get isAuthenticated;

  /// Emits one envelope. Returns false when it could not be written
  /// (offline) — the Outbox keeps it queued for the next flush.
  Future<bool> sendEnvelope(MessageEnvelopeV1 envelope);
}

/// Supplies the per-(local device -> remote device) ratchet session.
///
/// Each device pair has its OWN session (§15). Sessions are established
/// through X3DH on first contact and persisted in secure storage.
abstract interface class RatchetSessionProvider {
  /// Session for sending to [recipientDeviceId], creating it via X3DH if
  /// this is the first message to that device. Null when no session can
  /// be established (e.g. the peer published no key bundle).
  Future<RatchetState?> sessionForSending({
    required ConversationId conversationId,
    required DeviceId recipientDeviceId,
  });

  /// Persists mutated ratchet state after encrypt/decrypt. The ratchet
  /// advances on every operation; losing the new state breaks the chain.
  Future<void> persist({
    required ConversationId conversationId,
    required DeviceId remoteDeviceId,
    required RatchetState state,
  });
}

/// Checks whether communication with a peer is permitted (§29).
abstract interface class BlockPolicy {
  Future<bool> isBlocked({required AccountId self, required AccountId peer});
}

/// Outcome of a send request.
class SendResult {
  const SendResult({
    required this.messageId,
    required this.queuedDevices,
    required this.transmitted,
    this.rejectedReason,
  });

  final MessageId messageId;

  /// Number of per-device envelopes persisted to the Outbox.
  final int queuedDevices;

  /// True when at least one envelope reached the socket. False means
  /// queued offline — NOT an error (§11).
  final bool transmitted;

  /// Set when the send was refused outright (blocked peer, no devices).
  final String? rejectedReason;

  bool get isRejected => rejectedReason != null;
}

class MessageSendService {
  MessageSendService({
    required ConversationService conversations,
    required MessageEncryptionService encryption,
    required RatchetSessionProvider sessions,
    required OutboxStore outbox,
    required MessageTransport transport,
    required BlockPolicy blockPolicy,
    int Function()? clock,
  })  : _conversations = conversations,
        _encryption = encryption,
        _sessions = sessions,
        _outbox = outbox,
        _transport = transport,
        _blockPolicy = blockPolicy,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final ConversationService _conversations;
  final MessageEncryptionService _encryption;
  final RatchetSessionProvider _sessions;
  final OutboxStore _outbox;
  final MessageTransport _transport;
  final BlockPolicy _blockPolicy;
  final int Function() _clock;

  /// Encrypts, persists and (if online) transmits a message.
  Future<SendResult> send({
    required ConversationId conversationId,
    required AccountId selfAccountId,
    required DeviceId selfDeviceId,
    required AccountId peerAccountId,
    required MessageBody body,
    MessageId? messageId,
    int? expiresAtMs,
  }) async {
    final id = messageId ?? MessageId.generate();

    // §29: the block check runs BEFORE encryption or fan-out, so a
    // blocked peer costs no crypto work and leaves no queued state.
    if (await _blockPolicy.isBlocked(self: selfAccountId, peer: peerAccountId)) {
      return SendResult(
        messageId: id,
        queuedDevices: 0,
        transmitted: false,
        rejectedReason: 'BLOCKED',
      );
    }

    final targets = await _conversations.resolveTargets(
      selfAccountId: selfAccountId,
      sendingDeviceId: selfDeviceId,
      peerAccountId: peerAccountId,
    );

    if (targets.peerDevices.isEmpty) {
      // No active recipient device: queueing would retry forever against
      // a target that cannot exist. Fail fast instead (§12).
      return SendResult(
        messageId: id,
        queuedDevices: 0,
        transmitted: false,
        rejectedReason: 'NO_ACTIVE_RECIPIENT_DEVICE',
      );
    }

    final nowMs = _clock();
    final envelopes = <MessageEnvelopeV1>[];

    // One ciphertext per target device: each has its own ratchet session,
    // so the same plaintext yields N distinct ciphertexts (§15).
    for (final target in targets.all) {
      final state = await _sessions.sessionForSending(
        conversationId: conversationId,
        recipientDeviceId: target.deviceId,
      );
      if (state == null) continue; // no session establishable; skip device

      final encrypted = await _encryption.encrypt(
        state: state,
        body: body,
        messageId: id,
        conversationId: conversationId,
        senderAccountId: selfAccountId,
        senderDeviceId: selfDeviceId,
        recipientDeviceId: target.deviceId,
      );

      // The ratchet advanced — persist before the envelope is queued, or
      // a crash here would desynchronize the chain.
      await _sessions.persist(
        conversationId: conversationId,
        remoteDeviceId: target.deviceId,
        state: state,
      );

      envelopes.add(MessageEnvelopeV1(
        messageId: id,
        conversationId: conversationId,
        senderAccountId: selfAccountId,
        senderDeviceId: selfDeviceId,
        recipientDeviceId: target.deviceId,
        messageType: body.type,
        ciphertextBase64: encrypted.ciphertextBase64,
        ciphertextHeaderType: encrypted.headerType,
        clientTimestampMs: nowMs,
        expiresAtMs: expiresAtMs,
      ));
    }

    if (envelopes.isEmpty) {
      return SendResult(
        messageId: id,
        queuedDevices: 0,
        transmitted: false,
        rejectedReason: 'NO_SESSION',
      );
    }

    // §11 — persist BEFORE transmitting. This is the durability point.
    await _outbox.enqueueAll(envelopes);

    final transmitted = await flush();
    return SendResult(
      messageId: id,
      queuedDevices: envelopes.length,
      transmitted: transmitted,
    );
  }

  /// Transmits due Outbox entries. Safe to call repeatedly (on reconnect,
  /// on a timer, after a send). Retries reuse the SAME message_id so the
  /// server deduplicates instead of storing a second copy (§12).
  Future<bool> flush({int limit = 50}) async {
    if (!_transport.isAuthenticated) return false;

    final due = await _outbox.dueEntries(limit: limit);
    var anySent = false;

    for (final record in due) {
      // Record the attempt (and its backoff) BEFORE writing to the
      // socket: a crash mid-send must not produce a hot retry loop.
      await _outbox.markAttempt(
        record.envelope.messageId,
        record.envelope.recipientDeviceId,
      );

      final invalid = MessageEnvelopeV1.validateOutgoing(record.envelope);
      if (invalid != null) {
        // Malformed rows can never become valid — terminal (§12).
        await _outbox.markPermanentFailure(
          record.envelope.messageId,
          record.envelope.recipientDeviceId,
          invalid,
        );
        continue;
      }

      final ok = await _transport.sendEnvelope(record.envelope);
      if (ok) anySent = true;
      // On failure the row keeps its backoff and is retried later.
    }
    return anySent;
  }

  /// Applies a server `message.ack` (SENT — not delivered, §17).
  Future<void> onAck({
    required MessageId messageId,
    required DeviceId recipientDeviceId,
    int? serverSeq,
  }) =>
      _outbox.markAcked(messageId, recipientDeviceId, serverSeq: serverSeq);

  /// Applies a DELIVERED/READ receipt from a recipient device (§17).
  Future<void> onReceipt({
    required MessageId messageId,
    required DeviceId deviceId,
    required DeliveryState state,
  }) =>
      _outbox.markState(messageId, deviceId, state);

  /// Aggregate state across target devices (§17).
  Future<MessageDeliverySummary> deliveryState(MessageId messageId) =>
      _outbox.deliverySummary(messageId);

  /// User cancels an unsent message (§12).
  Future<void> cancel(MessageId messageId) => _outbox.cancel(messageId);
}
