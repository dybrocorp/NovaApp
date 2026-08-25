/// Per-recipient, per-device delivery state (§11, §17).
///
/// §17 is explicit: SENT, DELIVERED and READ are DISTINCT and must never
/// collapse into a single boolean. They also answer different questions:
///
///   queued     the message is in the local Outbox, not yet on the wire
///   sending    written to the socket, awaiting message.ack
///   sent       the SERVER stored it (message.ack). Says nothing about
///              the recipient — conflating this with "delivered" is the
///              classic messaging bug
///   delivered  a RECIPIENT DEVICE acknowledged receipt
///   read       the recipient opened the conversation
///   failed     terminal local failure (retries exhausted / permanent)
///
/// The engine tracks state PER DEVICE, because "delivered" is not a
/// property of a message but of a (message, device) pair (§17).
library;

import 'message_ids.dart';

enum DeliveryState {
  queued(0),
  sending(1),
  sent(2),
  delivered(3),
  read(4),
  failed(-1);

  const DeliveryState(this.rank);

  /// Monotonic progress rank. `failed` is negative: it is terminal but
  /// off the normal ladder.
  final int rank;

  bool get isTerminal => this == DeliveryState.failed || this == DeliveryState.read;
  bool get isPending => this == DeliveryState.queued || this == DeliveryState.sending;

  static DeliveryState fromName(String? raw) {
    for (final state in DeliveryState.values) {
      if (state.name == raw) return state;
    }
    return DeliveryState.queued;
  }
}

/// Forward-only state machine. States never move backwards: a late
/// `delivered` arriving after `read` must not downgrade the message.
abstract final class DeliveryStateMachine {
  static DeliveryState apply(DeliveryState current, DeliveryState next) {
    if (next == DeliveryState.failed) {
      // Once really delivered, a local failure is irrelevant.
      return current.rank >= DeliveryState.delivered.rank ? current : DeliveryState.failed;
    }
    if (current == DeliveryState.failed) {
      // A failed message can recover if the network later confirms it.
      return next.rank >= DeliveryState.sent.rank ? next : current;
    }
    return next.rank > current.rank ? next : current;
  }
}

/// Delivery state of one message towards ONE device.
class DeviceDeliveryState {
  const DeviceDeliveryState({
    required this.deviceId,
    required this.state,
    this.updatedAtMs,
  });

  final DeviceId deviceId;
  final DeliveryState state;
  final int? updatedAtMs;

  DeviceDeliveryState advance(DeliveryState next, {int? atMs}) => DeviceDeliveryState(
        deviceId: deviceId,
        state: DeliveryStateMachine.apply(state, next),
        updatedAtMs: atMs ?? updatedAtMs,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'device_id': deviceId.value,
        'state': state.name,
        if (updatedAtMs != null) 'updated_at_ms': updatedAtMs,
      };

  static DeviceDeliveryState fromMap(Map<String, dynamic> map) => DeviceDeliveryState(
        deviceId: DeviceId(map['device_id'] as String? ?? ''),
        state: DeliveryState.fromName(map['state'] as String?),
        updatedAtMs: map['updated_at_ms'] as int?,
      );
}

/// Aggregate delivery state of a message across every target device.
///
/// The summary is DERIVED, never stored as a boolean (§17): a message is
/// only "read" when every active device read it. Taking the minimum
/// avoids the common lie of showing "read" because the fastest of three
/// devices happened to open the chat.
class MessageDeliverySummary {
  const MessageDeliverySummary(this.perDevice);

  final List<DeviceDeliveryState> perDevice;

  bool get isEmpty => perDevice.isEmpty;

  /// Weakest state across devices — what the UI should show.
  DeliveryState get aggregate {
    if (perDevice.isEmpty) return DeliveryState.queued;
    final live = perDevice.where((e) => e.state != DeliveryState.failed).toList();
    if (live.isEmpty) return DeliveryState.failed;
    var lowest = live.first.state;
    for (final entry in live) {
      if (entry.state.rank < lowest.rank) lowest = entry.state;
    }
    return lowest;
  }

  /// True when at least one device reached [state].
  bool anyReached(DeliveryState state) =>
      perDevice.any((e) => e.state.rank >= state.rank);

  MessageDeliverySummary update(DeviceId deviceId, DeliveryState next, {int? atMs}) {
    final updated = <DeviceDeliveryState>[];
    var found = false;
    for (final entry in perDevice) {
      if (entry.deviceId.value == deviceId.value) {
        updated.add(entry.advance(next, atMs: atMs));
        found = true;
      } else {
        updated.add(entry);
      }
    }
    if (!found) {
      updated.add(DeviceDeliveryState(deviceId: deviceId, state: next, updatedAtMs: atMs));
    }
    return MessageDeliverySummary(updated);
  }
}
