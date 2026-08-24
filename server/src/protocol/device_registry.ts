/**
 * Server-side device registry view used by the handshake: maps
 * (account_id, device_id) -> registered Ed25519 public key + device status.
 *
 * TypeScript port of `lib/core/socket/protocol/device_registry.dart`.
 * In production the source of truth is the Supabase `devices`/`users`
 * tables (written by device_service.dart / identity_service.dart); the
 * `Directory` adapters (src/directory/) feed this registry.
 */

export type DeviceStatus = 'pending' | 'active' | 'revoked';

export interface DeviceRecord {
  accountId: string;
  deviceId: string;
  novaId: string;
  /** Raw 32-byte Ed25519 public key (as registered, never client-supplied). */
  ed25519PublicKey: Uint8Array;
  status: DeviceStatus;
}

export class DeviceRegistry {
  private readonly records = new Map<string, DeviceRecord>();

  /** Registers (or re-registers) a device with its Ed25519 identity key. */
  register(record: Omit<DeviceRecord, 'status'> & { status?: DeviceStatus }): void {
    this.records.set(record.deviceId, {
      ...record,
      status: record.status ?? 'active',
    });
  }

  byDeviceId(deviceId: string): DeviceRecord | null {
    return this.records.get(deviceId) ?? null;
  }

  isActive(deviceId: string): boolean {
    return this.records.get(deviceId)?.status === 'active';
  }

  /** Revokes a device. Revoked devices can never complete a handshake again. */
  revoke(deviceId: string): boolean {
    const record = this.records.get(deviceId);
    if (!record) return false;
    this.records.set(deviceId, { ...record, status: 'revoked' });
    return true;
  }

  /** Clears a device record entirely (tests). */
  delete(deviceId: string): void {
    this.records.delete(deviceId);
  }
}
