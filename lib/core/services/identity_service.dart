import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:novaapp/core/constants.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';

/// Manages the separation of Account ID / Nova ID / Device ID
/// and coordinates crypto key registration with Supabase.
class IdentityService {
  final SupabaseClient? _client;

  IdentityService(this._client);

  // ===== ACCOUNT ID =====
  // Internal UUID-based ID, never exposed to users.
  // Derived deterministically from Nova ID for consistency.

  /// Generates a deterministic account ID (UUID v5-like) from a Nova ID.
  /// This is an internal-only identifier.
  static String generateAccountId(String novaId) {
    final bytes = utf8.encode('novaapp-account-$novaId');
    final digest = md5.convert(bytes);
    return '${digest.toString().substring(0, 8)}-'
        '${digest.toString().substring(8, 12)}-'
        '${digest.toString().substring(12, 16)}-'
        '${digest.toString().substring(16, 20)}-'
        '${digest.toString().substring(20, 32)}';
  }

  // ===== DEVICE ID =====

  /// Generates a unique device ID based on timestamp + random.
  static String generateDeviceId() {
    final now = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final random = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'DEV-$now-$random'.toUpperCase();
  }

  // ===== KEY REGISTRATION =====

  /// Registers the device's identity key (IK) public component with Supabase.
  /// This is the long-lived key that identifies the account.
  Future<bool> registerIdentityKey({
    required String novaId,
    required String identityKeyPublic,
  }) async {
    if (_client == null) return false;
    try {
      await _client!.from(AppConstants.tableUsers).upsert({
        AppConstants.colNovaId: novaId,
        AppConstants.colPublicKey: identityKeyPublic,
        AppConstants.colUpdatedAt: DateTime.now().toIso8601String(),
      }, onConflict: AppConstants.colNovaId);
      LoggerService.info('Identity key registered', tag: 'Identity');
      return true;
    } catch (e) {
      LoggerService.error('Failed to register identity key', error: e, tag: 'Identity');
      return false;
    }
  }

  /// Uploads a signed pre-key (SPK) to Supabase.
  /// SPK is rotated periodically for forward secrecy.
  Future<bool> uploadSignedPreKey({
    required String novaId,
    required String signedPreKeyPublic,
    required String signedPreKeySignature,
    required int keyId,
  }) async {
    if (_client == null) return false;
    try {
      await _client!.from('signed_pre_keys').upsert({
        'nova_id': novaId,
        'key_id': keyId,
        'public_key': signedPreKeyPublic,
        'signature': signedPreKeySignature,
        'created_at': DateTime.now().toIso8601String(),
      }, onConflict: 'nova_id');
      LoggerService.info('Signed pre-key uploaded (id=$keyId)', tag: 'Identity');
      return true;
    } catch (e) {
      LoggerService.error('Failed to upload signed pre-key', error: e, tag: 'Identity');
      return false;
    }
  }

  /// Uploads one-time pre-keys (OPK) to Supabase.
  /// These are consumed once during initial key agreement.
  Future<bool> uploadOneTimePreKeys({
    required String novaId,
    required List<Map<String, dynamic>> keys,
  }) async {
    if (_client == null || keys.isEmpty) return false;
    try {
      final rows = keys.map((k) => {
        'nova_id': novaId,
        'key_id': k['key_id'],
        'public_key': k['public_key'],
        'created_at': DateTime.now().toIso8601String(),
      }).toList();

      await _client!.from('one_time_pre_keys').upsert(rows);
      LoggerService.info('Uploaded ${keys.length} one-time pre-keys', tag: 'Identity');
      return true;
    } catch (e) {
      LoggerService.error('Failed to upload one-time pre-keys', error: e, tag: 'Identity');
      return false;
    }
  }

  /// Fetches the recipient's key bundle for X3DH initialization.
  /// Returns { identity_key, signed_pre_key, one_time_pre_key (nullable) }
  Future<Map<String, String>?> fetchKeyBundle(String recipientNovaId) async {
    if (_client == null) return null;
    try {
      // 1. Get identity key
      final profile = await _client!
          .from(AppConstants.tableUsers)
          .select('public_key')
          .eq(AppConstants.colNovaId, recipientNovaId)
          .maybeSingle();

      final ik = profile?['public_key'] as String?;
      if (ik == null || ik.isEmpty) {
        LoggerService.warning('No identity key for $recipientNovaId', tag: 'Identity');
        return null;
      }

      // 2. Get signed pre-key
      final spk = await _client!
          .from('signed_pre_keys')
          .select('public_key')
          .eq('nova_id', recipientNovaId)
          .order('key_id', ascending: false)
          .limit(1)
          .maybeSingle();

      final spkPublic = spk?['public_key'] as String?;
      if (spkPublic == null || spkPublic.isEmpty) {
        LoggerService.warning('No signed pre-key for $recipientNovaId', tag: 'Identity');
        return null;
      }

      // 3. Get one-time pre-key (consumable)
      final opk = await _client!
          .from('one_time_pre_keys')
          .select('key_id, public_key')
          .eq('nova_id', recipientNovaId)
          .order('key_id', ascending: true)
          .limit(1)
          .maybeSingle();

      // 4. Delete the consumed one-time pre-key
      if (opk != null) {
        await _client!
            .from('one_time_pre_keys')
            .delete()
            .eq('nova_id', recipientNovaId)
            .eq('key_id', opk['key_id']);
      }

      return {
        'identity_key': ik,
        'signed_pre_key': spkPublic,
        if (opk != null) 'one_time_pre_key': opk['public_key'] as String,
      };
    } catch (e) {
      LoggerService.error('Failed to fetch key bundle', error: e, tag: 'Identity');
      return null;
    }
  }

  // ===== KEY ROTATION =====

  /// Checks if the signed pre-key should be rotated (older than [maxAge]).
  Future<bool> shouldRotateSPK(String novaId, {Duration maxAge = const Duration(days: 7)}) async {
    if (_client == null) return false;
    try {
      final record = await _client!
          .from('signed_pre_keys')
          .select('created_at')
          .eq('nova_id', novaId)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (record == null) return true; // No key = needs rotation

      final createdAt = DateTime.parse(record['created_at']);
      return DateTime.now().difference(createdAt) > maxAge;
    } catch (_) {
      return true;
    }
  }

  /// Returns how many one-time pre-keys remain for this device.
  Future<int> getOneTimePreKeyCount(String novaId) async {
    if (_client == null) return 0;
    try {
      final result = await _client!
          .from('one_time_pre_keys')
          .select('key_id')
          .eq('nova_id', novaId);
      return result.length;
    } catch (_) {
      return 0;
    }
  }
}

final identityServiceProvider = Provider<IdentityService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return IdentityService(client);
});
