import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/features/auth/data/identity_repository.dart';

final identityRepositoryProvider = Provider((ref) => IdentityRepository());

final identityProvider = FutureProvider<String?>((ref) async {
  return await ref.watch(identityRepositoryProvider).getId();
});

final nameProvider = FutureProvider<String?>((ref) async {
  return await ref.watch(identityRepositoryProvider).getName();
});

final phoneProvider = FutureProvider<String?>((ref) async {
  return await ref.watch(identityRepositoryProvider).getPhone();
});

final avatarProvider = FutureProvider<String?>((ref) async {
  return await ref.watch(identityRepositoryProvider).getAvatarPath();
});
