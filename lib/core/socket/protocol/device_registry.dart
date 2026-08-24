/// REFERENCE implementation of the server-side device registry used by the
/// handshake: maps (account_id, device_id) -> registered Ed25519 public key
/// + device status.
///
/// Source of truth in production: Supabase `devices` + `users` tables
/// (device_service.dart / identity_service.dart already write them). This
/// in-memory model mirrors the checks the realtime server performs on every
/// handshake and is exercised by the protocol tests.
class DeviceRegistry {
  final Map<String, DeviceRecord> _byDeviceId = <String, DeviceRecord>{};

  /// Registers (or re-registers) a device with its Ed25519 identity key.
  void register({
    required String accountId,
    required String deviceId,
    required String novaId,
    required List<int> ed25519PublicKey,
  }) {
    _byDeviceId[deviceId] = DeviceRecord(
      accountId: accountId,
      deviceId: deviceId,
      novaId: novaId,
      ed25519PublicKey: ed25519PublicKey,
      status: DeviceStatus.active,
    );
  }

  DeviceRecord? byDeviceId(String deviceId) => _byDeviceId[deviceId];

  bool isActive(String deviceId) =>
      _byDeviceId[deviceId]?.status == DeviceStatus.active;

  /// Revokes a device. Revoked devices can never complete a handshake again
  /// and all their live sessions are invalidated (the caller invokes
  /// SessionRegistry.revokeByDevice).
  void revoke(String deviceId) {
    final record = _byDeviceId[deviceId];
    if (record == null) return;
    _byDeviceId[deviceId] = DeviceRecord(
      accountId: record.accountId,
      deviceId: record.deviceId,
      novaId: record.novaId,
      ed25519PublicKey: record.ed25519PublicKey,
      status: DeviceStatus.revoked,
    );
  }
}

enum DeviceStatus { pending, active, revoked }

class DeviceRecord {
  const DeviceRecord({
    required this.accountId,
    required this.deviceId,
    required this.novaId,
    required this.ed25519PublicKey,
    required this.status,
  });

  final String accountId;
  final String deviceId;
  final String novaId;
  final List<int> ed25519PublicKey;
  final DeviceStatus status;
}
