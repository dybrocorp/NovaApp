import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:novaapp/core/constants.dart';
import 'package:novaapp/core/utils/identity_utils.dart';
import 'package:novaapp/core/services/logger_service.dart';

class IdentityRepository {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  // ===== NOVA ID =====

  Future<String?> getId() async {
    try {
      return await _storage.read(key: AppConstants.keyNovaId);
    } catch (e) {
      LoggerService.error('Error reading ID', error: e, tag: 'Identity');
      await _storage.delete(key: AppConstants.keyNovaId);
      return null;
    }
  }

  Future<String> createIdentity() async {
    final existingId = await getId();
    if (existingId != null) return existingId;

    final newId = IdentityUtils.generateId();
    await _storage.write(key: AppConstants.keyNovaId, value: newId);
    return newId;
  }

  Future<void> restoreIdentity(String id) async {
    await _storage.write(key: AppConstants.keyNovaId, value: id);
  }

  // ===== ACCOUNT ID (independent, CSPRNG — not derived from Nova ID) =====

  Future<String?> getAccountId() async {
    try {
      var accountId = await _storage.read(key: AppConstants.keyAccountId);
      if (accountId == null) {
        // Generate a fresh, independent Account ID (not linked to Nova ID)
        accountId = IdentityUtils.generateAccountId();
        await _storage.write(key: AppConstants.keyAccountId, value: accountId);
      }
      return accountId;
    } catch (e) {
      LoggerService.error('Error getting account ID', error: e, tag: 'Identity');
      return null;
    }
  }

  // ===== DEVICE ID =====

  Future<String> getOrCreateDeviceId() async {
    var deviceId = await _storage.read(key: AppConstants.keyDeviceId);
    if (deviceId == null) {
      deviceId = IdentityUtils.generateDeviceId();
      await _storage.write(key: AppConstants.keyDeviceId, value: deviceId);
    }
    return deviceId;
  }

  // ===== PROFILE =====

  Future<void> saveName(String name) async {
    await _storage.write(key: AppConstants.keyUserName, value: name);
  }

  Future<String?> getName() async {
    return await _storage.read(key: AppConstants.keyUserName);
  }

  Future<void> saveAvatarPath(String path) async {
    await _storage.write(key: AppConstants.keyAvatar, value: path);
  }

  Future<String?> getAvatarPath() async {
    return await _storage.read(key: AppConstants.keyAvatar);
  }

  // ===== DELETION =====

  /// Deletes only NovaApp-specific data (not all secure storage).
  Future<void> deleteAllData() async {
    final keys = [
      AppConstants.keyNovaId,
      AppConstants.keyAccountId,
      AppConstants.keyDeviceId,
      AppConstants.keyPrivateKey,
      AppConstants.keyPublicKey,
      AppConstants.keyUserName,
      AppConstants.keyAvatar,
      AppConstants.keyIdentityKeyPair,
      AppConstants.keySignedPreKeyPair,
      AppConstants.keySignedPreKeyId,
      AppConstants.keyOneTimePreKeyPairs,
    ];
    for (final key in keys) {
      await _storage.delete(key: key);
    }
  }
}
