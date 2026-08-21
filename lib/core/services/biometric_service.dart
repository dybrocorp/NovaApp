import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/services/logger_service.dart';

/// Local biometric authentication. Never sends biometric data to server.
///
/// Supports:
///   - Fingerprint (Android/iOS)
///   - Face ID (iOS)
///   - Face Recognition (Android)
///
/// Biometric data stays on device's secure enclave. Server never sees it.
/// Used only for: local app unlock, transaction confirmation.

class BiometricService {
  final LocalAuthentication _auth = LocalAuthentication();

  /// Returns true if biometric hardware is available and enrolled.
  Future<bool> isAvailable() async {
    try {
      final canCheck = await _auth.canCheckBiometrics;
      final isSupported = await _auth.isDeviceSupported();
      return canCheck && isSupported;
    } catch (e) {
      LoggerService.warning('Biometric check failed: $e', tag: 'Biometric');
      return false;
    }
  }

  /// Returns the list of enrolled biometric types.
  Future<List<BiometricType>> getEnrolledTypes() async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (e) {
      LoggerService.warning('Failed to get biometric types: $e', tag: 'Biometric');
      return [];
    }
  }

  /// Prompts the user for biometric authentication.
  /// [reason] is displayed in the biometric prompt dialog.
  /// Returns true if authentication succeeded.
  Future<bool> authenticate({
    String reason = 'Autenticacion requerida',
  }) async {
    try {
      final result = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false, // Allow fallback to PIN
        sensitiveTransaction: true,
        persistAcrossBackgrounding: true,
      );
      if (result) {
        LoggerService.info('Biometric auth succeeded', tag: 'Biometric');
      }
      return result;
    } on PlatformException catch (e) {
      LoggerService.warning('Biometric auth error: ${e.message}', tag: 'Biometric');
      return false;
    }
  }

  /// Returns true if the user has enrolled at least one biometric.
  Future<bool> hasEnrolledBiometrics() async {
    try {
      final types = await _auth.getAvailableBiometrics();
      return types.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Stops any ongoing biometric authentication.
  Future<void> stopAuthentication() async {
    try {
      await _auth.stopAuthentication();
    } catch (_) {}
  }
}

final biometricServiceProvider = Provider((ref) => BiometricService());
