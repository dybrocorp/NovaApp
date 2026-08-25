/// Inbound message pipeline (§13, §17, §18, §19, §20, §21, §22).
///
/// Implements the §13 order exactly:
///
///   socket event -> validate -> PERSIST -> DELIVERED -> decrypt -> apply
///
/// Persisting before acknowledging is deliberate: if the app dies right
/// after receiving, the envelope is already on disk and is reprocessed on
/// restart. Acknowledging first would let the server consider delivered a
/// message the client never stored.
///
/// Decryption happens AFTER persistence and AFTER the DELIVERED receipt,
/// because "the bytes arrived" and "the bytes were readable" are
/// different facts. A ciphertext that fails authentication is still a
/// received message; it is flagged, never silently dropped and never
/// re-processed.
library;

import '../../services/double_ratchet_service.dart';
import '../crypto/message_encryption_service.dart';
import '../model/message_body.dart';
import '../model/message_envelope_v1.dart';
import '../model/message_ids.dart';
import '../model/message_type.dart';
import '../store/inbox_store.dart';
import '../store/sync_cursor_store.dart';

/// Emits receipts back to the server.
abstract interface class ReceiptEmitter {
  Future<void> sendDelivered({
    required ConversationId conversationId,
    required MessageId messageId,
  });

  Future<void> sendRead({
    required ConversationId conversationId,
    required int lastReadSeq,
  });
}

/// Supplies the receiving ratchet session for a remote device.
abstract interface class InboundSessionProvider {
  Future<RatchetState?> sessionForReceiving({
    required ConversationId conversationId,
    required DeviceId senderDeviceId,
  });

  Future<void> persist({
    required ConversationId conversationId,
    required DeviceId remoteDeviceId,
    required RatchetState state,
  });
}

/// A decrypted message ready for the UI/domain layer.
class DecryptedMessage {
  const DecryptedMessage({
    required this.messageId,
    required this.conversationId,
    required this.senderAccountId,
    required this.senderDeviceId,
    required this.body,
    required this.serverSeq,
    this.clientTimestampMs,
    this.expiresAtMs,
  });

  final MessageId messageId;
  final ConversationId conversationId;
  final AccountId senderAccountId;
  final DeviceId senderDeviceId;
  final MessageBody body;
  final int? serverSeq;
  final int? clientTimestampMs;
  final int? expiresAtMs;
}

/// What the engine did with an inbound envelope.
enum ReceiveOutcome {
  applied,
  duplicate,
  rejected,
  decryptFailed,
  ignoredBlocked,
}

class ReceiveResult {
  const ReceiveResult(this.outcome, {this.message});
  final ReceiveOutcome outcome;
  final DecryptedMessage? message;
}

class MessageReceiveService {
  MessageReceiveService({
    required InboxStore inbox,
    required SyncCursorStore cursors,
    required MessageEncryptionService encryption,
    required InboundSessionProvider sessions,
    required ReceiptEmitter receipts,
    required DeviceId localDeviceId,
    Future<bool> Function(AccountId sender)? isSenderBlocked,
  })  : _inbox = inbox,
        _cursors = cursors,
        _encryption = encryption,
        _sessions = sessions,
        _receipts = receipts,
        _localDeviceId = localDeviceId,
        _isSenderBlocked = isSenderBlocked;

  final InboxStore _inbox;
  final SyncCursorStore _cursors;
  final MessageEncryptionService _encryption;
  final InboundSessionProvider _sessions;
  final ReceiptEmitter _receipts;
  final DeviceId _localDeviceId;
  final Future<bool> Function(AccountId sender)? _isSenderBlocked;

  /// Handles a raw `message.new` payload.
  Future<ReceiveResult> onMessageNew(
    Map<String, dynamic> payload, {
    bool emitDelivered = true,
  }) async {
    final envelope = MessageEnvelopeV1.tryParseInbound(payload);
    if (envelope == null) return const ReceiveResult(ReceiveOutcome.rejected);
    return ingest(envelope, emitDelivered: emitDelivered);
  }

  /// Full §13 pipeline for one envelope.
  Future<ReceiveResult> ingest(
    MessageEnvelopeV1 envelope, {
    bool emitDelivered = true,
  }) async {
    // §29: drop traffic from a blocked sender before storing anything.
    if (_isSenderBlocked != null &&
        await _isSenderBlocked(envelope.senderAccountId)) {
      return const ReceiveResult(ReceiveOutcome.ignoredBlocked);
    }

    // 1) PERSIST FIRST. Dedup is enforced by the primary key, so a
    //    message delivered live and replayed by sync applies once (§13).
    final accepted = await _inbox.accept(envelope);
    if (accepted == InboxAcceptResult.duplicate) {
      return const ReceiveResult(ReceiveOutcome.duplicate);
    }
    if (accepted == InboxAcceptResult.rejected) {
      return const ReceiveResult(ReceiveOutcome.rejected);
    }

    // 2) DELIVERED: the bytes are durably stored, which is exactly what
    //    this receipt asserts — not that they were readable (§17).
    if (emitDelivered) {
      await _receipts.sendDelivered(
        conversationId: envelope.conversationId,
        messageId: envelope.messageId,
      );
      await _inbox.markDeliveredSent(envelope.messageId);
    }

    // 3) Decrypt.
    final result = await _decrypt(envelope);

    // 4) Advance the cursor only AFTER the event was applied (§14).
    if (result.outcome == ReceiveOutcome.applied) {
      await _cursors.advance(
        envelope.conversationId,
        logSeq: envelope.logSeq,
        serverSeq: envelope.serverSeq,
      );
    }
    return result;
  }

  Future<ReceiveResult> _decrypt(MessageEnvelopeV1 envelope) async {
    final state = await _sessions.sessionForReceiving(
      conversationId: envelope.conversationId,
      senderDeviceId: envelope.senderDeviceId,
    );
    if (state == null) {
      // No session yet: keep the envelope so it can be retried once the
      // session exists. Not a failure — do NOT mark it processed.
      return const ReceiveResult(ReceiveOutcome.rejected);
    }

    try {
      final body = await _encryption.decrypt(
        state: state,
        envelope: envelope,
        localDeviceId: _localDeviceId,
      );

      await _sessions.persist(
        conversationId: envelope.conversationId,
        remoteDeviceId: envelope.senderDeviceId,
        state: state,
      );
      await _inbox.markProcessed(envelope.messageId);

      return ReceiveResult(
        ReceiveOutcome.applied,
        message: DecryptedMessage(
          messageId: envelope.messageId,
          conversationId: envelope.conversationId,
          senderAccountId: envelope.senderAccountId,
          senderDeviceId: envelope.senderDeviceId,
          body: body,
          serverSeq: envelope.serverSeq,
          clientTimestampMs: envelope.clientTimestampMs,
          expiresAtMs: envelope.expiresAtMs,
        ),
      );
    } on MessageDecryptionError {
      // Tampered, replayed or mis-routed. Flagged and kept so the same id
      // can never be retried into a second processing attempt.
      await _inbox.markDecryptFailed(envelope.messageId);
      return const ReceiveResult(ReceiveOutcome.decryptFailed);
    }
  }

  /// Reprocesses envelopes stored but not applied (crash recovery).
  Future<List<DecryptedMessage>> resumePending({int limit = 100}) async {
    final pending = await _inbox.pendingProcessing(limit: limit);
    final recovered = <DecryptedMessage>[];
    for (final record in pending) {
      final result = await _decrypt(record.envelope);
      if (result.message != null) recovered.add(result.message!);
    }
    return recovered;
  }

  /// Emits READ up to [lastReadSeq] (§17).
  ///
  /// The server clamps the value to what actually exists, so an
  /// optimistic client cannot mark the future as read.
  Future<void> markConversationRead({
    required ConversationId conversationId,
    required int lastReadSeq,
  }) =>
      _receipts.sendRead(conversationId: conversationId, lastReadSeq: lastReadSeq);

  /// Validates a reply target before rendering (§20).
  ///
  /// §20: "el cliente debe verificar que el mensaje citado pertenezca a la
  /// conversación. No confiar solamente en metadata del cliente." The
  /// quoted id lives inside the ciphertext, so the sender authenticated
  /// it — but a malicious SENDER could still quote a message from another
  /// conversation to fabricate context. This checks locally.
  Future<bool> isValidReplyTarget({
    required ConversationId conversationId,
    required MessageId quotedMessageId,
  }) async {
    final records = await _inbox.forConversation(conversationId, limit: 1000);
    return records.any((r) => r.envelope.messageId.value == quotedMessageId.value);
  }

  /// Validates a mutation target: edits, deletions and reactions may only
  /// target a message of the SAME conversation, and an edit or deletion
  /// may only come from the ORIGINAL sender (§18, §19, §21).
  Future<bool> isValidMutation({
    required ConversationId conversationId,
    required AccountId actorAccountId,
    required MessageBody body,
  }) async {
    final target = body.editTargetMessageId ??
        body.deletionTargetMessageId ??
        body.reactionTargetMessageId;
    if (target == null) return false;

    final records = await _inbox.forConversation(conversationId, limit: 1000);
    final match = records
        .where((r) => r.envelope.messageId.value == target.value)
        .toList();
    if (match.isEmpty) return false;

    // A reaction may come from any participant; an edit or a deletion
    // only from the author (§18).
    if (body.type == MessageType.reaction) return true;
    return match.first.envelope.senderAccountId.value == actorAccountId.value;
  }

  /// Deletes locally expired disappearing messages (§22).
  Future<int> purgeExpired() => _inbox.purgeExpired();
}
