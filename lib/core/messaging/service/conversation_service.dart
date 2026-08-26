/// Conversation lifecycle and device-fan-out targeting (§4, §15, §16).
///
/// Two responsibilities, both security-relevant:
///
///  1. Create/resolve a 1:1 conversation with an OPAQUE random id (§4).
///  2. Decide WHICH devices a message is encrypted for (§15/§16).
///
/// The device list is the security boundary of the fan-out: a device that
/// is not in it never receives a ciphertext it could decrypt. §16 is
/// explicit — an unknown device gets no automatic access, so only
/// `status == 'active'` devices are targeted, and the list comes from the
/// server-side directory, never from a client claim.
library;

import '../model/message_ids.dart';

/// A device that may receive messages for an account.
class TargetDevice {
  const TargetDevice({
    required this.accountId,
    required this.deviceId,
    required this.status,
  });

  final AccountId accountId;
  final DeviceId deviceId;

  /// 'active' | 'pending' | 'revoked'. Only 'active' is a valid target.
  final String status;

  bool get isActive => status == 'active';
}

/// Source of truth for device lists. Backed by the Supabase `devices`
/// table in production; injected so the engine stays testable.
abstract interface class DeviceDirectory {
  /// Active devices of an account. MUST exclude revoked and pending.
  Future<List<TargetDevice>> activeDevicesFor(AccountId accountId);
}

/// Persistence for conversation metadata.
abstract interface class ConversationRegistry {
  Future<ConversationId?> findDirectConversation({
    required AccountId self,
    required AccountId peer,
  });

  Future<void> saveDirectConversation({
    required ConversationId conversationId,
    required AccountId self,
    required AccountId peer,
    int? disappearingTtlSeconds,
  });

  Future<int?> disappearingTtlSeconds(ConversationId conversationId);
}

/// The set of devices one message must be encrypted for.
class FanOutTargets {
  const FanOutTargets({
    required this.peerDevices,
    required this.ownOtherDevices,
  });

  /// Recipient's active devices.
  final List<TargetDevice> peerDevices;

  /// Sender's OTHER active devices, so the conversation stays in sync
  /// across the sender's own devices (§15). Excludes the sending device.
  final List<TargetDevice> ownOtherDevices;

  List<TargetDevice> get all => <TargetDevice>[...peerDevices, ...ownOtherDevices];

  bool get isEmpty => all.isEmpty;
  int get deviceCount => all.length;
}

class ConversationService {
  ConversationService({
    required DeviceDirectory directory,
    required ConversationRegistry registry,
  })  : _directory = directory,
        _registry = registry;

  final DeviceDirectory _directory;
  final ConversationRegistry _registry;

  /// Returns the existing 1:1 conversation or creates one.
  ///
  /// The id is a fresh random UUID, never derived from the participants
  /// (§4): a derived id would let anyone probe whether two accounts talk.
  Future<ConversationId> ensureDirectConversation({
    required AccountId self,
    required AccountId peer,
  }) async {
    final existing = await _registry.findDirectConversation(self: self, peer: peer);
    if (existing != null) return existing;

    final conversationId = ConversationId.generate();
    await _registry.saveDirectConversation(
      conversationId: conversationId,
      self: self,
      peer: peer,
    );
    return conversationId;
  }

  /// Resolves the devices a message must be encrypted for.
  ///
  /// Filters to ACTIVE devices only (§16): a revoked or pending device
  /// must never receive a ciphertext it could open.
  Future<FanOutTargets> resolveTargets({
    required AccountId selfAccountId,
    required DeviceId sendingDeviceId,
    required AccountId peerAccountId,
  }) async {
    final peerDevices = await _directory.activeDevicesFor(peerAccountId);
    final ownDevices = await _directory.activeDevicesFor(selfAccountId);

    return FanOutTargets(
      peerDevices: peerDevices.where((d) => d.isActive).toList(),
      ownOtherDevices: ownDevices
          .where((d) => d.isActive && d.deviceId.value != sendingDeviceId.value)
          .toList(),
    );
  }

  /// Disappearing-message TTL for a conversation, if configured (§22).
  Future<int?> disappearingTtlSeconds(ConversationId conversationId) =>
      _registry.disappearingTtlSeconds(conversationId);
}
