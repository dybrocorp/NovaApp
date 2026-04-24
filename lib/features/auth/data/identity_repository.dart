import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:novaapp/core/utils/identity_utils.dart';

class IdentityRepository {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const String _idKey = 'nova_id';
  static const String _nameKey = 'user_name';
  static const String _phoneKey = 'user_phone';
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

  Future<void> saveName(String name) async {
    await _storage.write(key: _nameKey, value: name);
  }

  Future<String?> getName() async {
    return await _storage.read(key: _nameKey);
  }

  Future<void> savePhone(String phone) async {
    await _storage.write(key: _phoneKey, value: phone);
  }

  Future<String?> getPhone() async {
    return await _storage.read(key: _phoneKey);
  }

  Future<void> saveAvatarPath(String path) async {
    await _storage.write(key: _avatarKey, value: path);
  }

  Future<String?> getAvatarPath() async {
    return await _storage.read(key: _avatarKey);
  }
}
