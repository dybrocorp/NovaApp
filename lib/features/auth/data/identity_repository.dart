import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:novaapp/core/utils/identity_utils.dart';

class IdentityRepository {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const String _idKey = 'nova_id';
  static const String _nameKey = 'user_name';

  static const String _avatarKey = 'user_avatar';

  Future<String?> getId() async {
    return await _storage.read(key: _idKey);
  }

  Future<String> createIdentity() async {
    final existingId = await getId();
    if (existingId != null) return existingId;

    final newId = IdentityUtils.generateId();
    await _storage.write(key: _idKey, value: newId);
    return newId;
  }

  Future<void> restoreIdentity(String id) async {
    await _storage.write(key: _idKey, value: id);
  }

  Future<void> saveName(String name) async {
    await _storage.write(key: _nameKey, value: name);
  }

  Future<String?> getName() async {
    return await _storage.read(key: _nameKey);
  }

  Future<void> saveAvatarPath(String path) async {
    await _storage.write(key: _avatarKey, value: path);
  }

  Future<String?> getAvatarPath() async {
    return await _storage.read(key: _avatarKey);
  }

  /// Permanently deletes ALL user data from secure storage.
  Future<void> deleteAllData() async {
    await _storage.deleteAll();
  }
}
