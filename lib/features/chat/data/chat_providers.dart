import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/services/database_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';
import 'package:novaapp/core/services/encryption_service.dart';
import 'package:novaapp/core/services/notification_service.dart';
import 'package:novaapp/core/services/moderation_service.dart';

import 'package:novaapp/features/auth/presentation/auth_providers.dart';
import 'package:novaapp/features/chat/domain/chat_repository.dart';
import 'package:novaapp/features/chat/data/chat_repository_impl.dart';
import 'package:novaapp/features/chat/domain/models.dart';

final databaseServiceProvider = Provider((ref) => DatabaseService());

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final dbService = ref.watch(databaseServiceProvider);
  final encryptionService = ref.watch(encryptionServiceProvider);
  final supabaseService = ref.watch(supabaseServiceProvider);
  final notificationService = NotificationService();
  final identityRepository = ref.watch(identityRepositoryProvider);
  final moderationService = ref.watch(moderationServiceProvider);
  return ChatRepositoryImpl(dbService, encryptionService, supabaseService, notificationService, identityRepository, moderationService);
});

final contactsProvider = FutureProvider<List<ChatContact>>((ref) async {
  return await ref.watch(chatRepositoryProvider).getContacts();
});

final messagesProvider = StreamProvider.family<List<Message>, String>((ref, contactId) {
  final repo = ref.watch(chatRepositoryProvider);
  return repo.watchMessages(contactId);
});
