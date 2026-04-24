import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/services/database_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';
import 'package:novaapp/core/services/encryption_service.dart';
import 'package:novaapp/features/chat/domain/chat_repository.dart';
import 'package:novaapp/features/chat/data/chat_repository_impl.dart';
import 'package:novaapp/features/chat/domain/models.dart';

final databaseServiceProvider = Provider((ref) => DatabaseService());

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final dbService = ref.watch(databaseServiceProvider);
  final encryptionService = ref.watch(encryptionServiceProvider);
  final supabaseService = ref.watch(supabaseServiceProvider);
  return ChatRepositoryImpl(dbService, encryptionService, supabaseService);
});

final contactsProvider = FutureProvider<List<ChatContact>>((ref) async {
  return await ref.watch(chatRepositoryProvider).getContacts();
});

final messagesProvider = StreamProvider.family<List<Message>, String>((ref, contactId) {
  final repo = ref.watch(chatRepositoryProvider);
  return repo.watchMessages(contactId);
});
