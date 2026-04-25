import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/features/settings/data/security_repository.dart';

final securityRepositoryProvider = Provider((ref) => SecurityRepository());

final appLockEnabledProvider = StateProvider<bool>((ref) => false);
final appLockTypeProvider = StateProvider<String>((ref) => 'none');
final biometricEnabledProvider = StateProvider<bool>((ref) => false);

// Advanced Security Providers
final inactivityTimeoutProvider = StateProvider<int>((ref) => 0);
final wipeOnFailedProvider = StateProvider<bool>((ref) => false);
final screenSecurityProvider = StateProvider<bool>((ref) => false);
final lockOnScreenOffProvider = StateProvider<bool>((ref) => false);
final failedAttemptsProvider = StateProvider<int>((ref) => 0);

// Initialization provider
final securityInitProvider = FutureProvider<void>((ref) async {
  final repo = ref.read(securityRepositoryProvider);
  ref.read(appLockEnabledProvider.notifier).state = await repo.isLockEnabled();
  ref.read(appLockTypeProvider.notifier).state = await repo.getLockType();
  ref.read(biometricEnabledProvider.notifier).state = await repo.isBiometricEnabled();
  
  ref.read(inactivityTimeoutProvider.notifier).state = await repo.getInactivityTimeout();
  ref.read(wipeOnFailedProvider.notifier).state = await repo.isWipeOnFailedEnabled();
  ref.read(screenSecurityProvider.notifier).state = await repo.isScreenSecurityEnabled();
  ref.read(lockOnScreenOffProvider.notifier).state = await repo.isLockOnScreenOffEnabled();
  ref.read(failedAttemptsProvider.notifier).state = await repo.getFailedAttempts();
});
