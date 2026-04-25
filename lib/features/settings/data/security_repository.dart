import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

class SecurityRepository {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final LocalAuthentication _auth = LocalAuthentication();

  static const String _pinKey = 'app_lock_pin';
  static const String _patternKey = 'app_lock_pattern';
  static const String _biometricKey = 'app_lock_biometric';
  static const String _lockEnabledKey = 'app_lock_enabled';
  static const String _lockTypeKey = 'app_lock_type'; 
  
  // Advanced Security Keys
  static const String _failedAttemptsKey = 'security_failed_attempts';
  static const String _inactivityTimeoutKey = 'security_inactivity_timeout'; // minutes
  static const String _wipeOnFailedKey = 'security_wipe_on_failed';
  static const String _screenSecurityKey = 'security_screen_protection';
  static const String _lockOnScreenOffKey = 'security_lock_on_screen_off';

  // --- App Lock General ---
  Future<bool> isLockEnabled() async {
    final val = await _storage.read(key: _lockEnabledKey);
    return val == 'true';
  }

  Future<void> setLockEnabled(bool enabled) async {
    await _storage.write(key: _lockEnabledKey, value: enabled.toString());
  }

  Future<String> getLockType() async {
    return await _storage.read(key: _lockTypeKey) ?? 'none';
  }

  Future<void> setLockType(String type) async {
    await _storage.write(key: _lockTypeKey, value: type);
  }

  // --- PIN ---
  Future<void> savePin(String pin) async {
    await _storage.write(key: _pinKey, value: pin);
    await resetFailedAttempts();
  }

  Future<String?> getPin() async {
    return await _storage.read(key: _pinKey);
  }

  // --- Pattern ---
  Future<void> savePattern(List<int> pattern) async {
    await _storage.write(key: _patternKey, value: pattern.join(','));
    await resetFailedAttempts();
  }

  Future<List<int>?> getPattern() async {
    final val = await _storage.read(key: _patternKey);
    if (val == null) return null;
    return val.split(',').map(int.parse).toList();
  }

  // --- Biometrics ---
  Future<bool> canCheckBiometrics() async {
    return await _auth.canCheckBiometrics;
  }

  Future<bool> isBiometricEnabled() async {
    final val = await _storage.read(key: _biometricKey);
    return val == 'true';
  }

  Future<void> setBiometricEnabled(bool enabled) async {
    await _storage.write(key: _biometricKey, value: enabled.toString());
  }

  Future<bool> authenticateWithBiometrics() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Por favor, autentícate para acceder a NovaApp',
      );
    } catch (e) {
      return false;
    }
  }

  // --- Advanced Security Features ---

  Future<int> getFailedAttempts() async {
    final val = await _storage.read(key: _failedAttemptsKey);
    return int.tryParse(val ?? '0') ?? 0;
  }

  Future<void> incrementFailedAttempts() async {
    final current = await getFailedAttempts();
    await _storage.write(key: _failedAttemptsKey, value: (current + 1).toString());
  }

  Future<void> resetFailedAttempts() async {
    await _storage.write(key: _failedAttemptsKey, value: '0');
  }

  Future<int> getInactivityTimeout() async {
    final val = await _storage.read(key: _inactivityTimeoutKey);
    return int.tryParse(val ?? '0') ?? 0; // 0 = Never
  }

  Future<void> setInactivityTimeout(int minutes) async {
    await _storage.write(key: _inactivityTimeoutKey, value: minutes.toString());
  }

  Future<bool> isWipeOnFailedEnabled() async {
    final val = await _storage.read(key: _wipeOnFailedKey);
    return val == 'true';
  }

  Future<void> setWipeOnFailed(bool enabled) async {
    await _storage.write(key: _wipeOnFailedKey, value: enabled.toString());
  }

  Future<bool> isScreenSecurityEnabled() async {
    final val = await _storage.read(key: _screenSecurityKey);
    return val == 'true';
  }

  Future<void> setScreenSecurity(bool enabled) async {
    await _storage.write(key: _screenSecurityKey, value: enabled.toString());
  }

  Future<bool> isLockOnScreenOffEnabled() async {
    final val = await _storage.read(key: _lockOnScreenOffKey);
    return val == 'true';
  }

  Future<void> setLockOnScreenOff(bool enabled) async {
    await _storage.write(key: _lockOnScreenOffKey, value: enabled.toString());
  }
}
