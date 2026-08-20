import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:novaapp/core/constants.dart';
import 'logger_service.dart';

class SupabaseService {
  static bool _isInitialized = false;

  static Future<void> initialize() async {
    final url = dotenv.env['SUPABASE_URL'] ?? '';
    final anonKey = dotenv.env['SUPABASE_ANON_KEY'] ?? '';

    if (url.isEmpty || anonKey.isEmpty) {
      throw Exception('SUPABASE_URL and SUPABASE_ANON_KEY must be set in .env');
    }

    await Supabase.initialize(url: url, anonKey: anonKey);
    _isInitialized = true;
    LoggerService.info('Supabase initialized', tag: 'Supabase');
  }

  SupabaseClient? get client {
    if (!_isInitialized) {
      LoggerService.warning('Supabase not initialized', tag: 'Supabase');
      return null;
    }
    return Supabase.instance.client;
  }

  User? get currentUser => client?.auth.currentUser;

  // ===== HELPER: try primary table, fallback to secondary =====

  /// Executes [operation] on [primaryTable]. If it fails, tries [fallbackTable].
  Future<T?> _withTableFallback<T>(
    String primaryTable,
    String fallbackTable,
    Future<T> Function(PostgrestFilterBuilder<dynamic>) operation, {
    String? logContext,
  }) async {
    final c = client;
    if (c == null) return null;
    try {
      return await operation(c.from(primaryTable));
    } catch (e) {
      LoggerService.debug(
        '$logContext: $primaryTable failed, trying $fallbackTable',
        tag: 'Supabase',
      );
      try {
        return await operation(c.from(fallbackTable));
      } catch (e2) {
        LoggerService.error(
          '$logContext: both tables failed',
          error: e2,
          tag: 'Supabase',
        );
        return null;
      }
    }
  }

  // ===== AUTHENTICATION =====

  Future<AuthResponse?> createAnonymousSession() async {
    final c = client;
    if (c == null) return null;
    if (c.auth.currentUser != null) return null;

    final response = await c.auth.signInAnonymously();
    LoggerService.info('Anonymous session: ${response.user?.id}', tag: 'Supabase');
    return response;
  }

  Future<void> signOut() async {
    await client?.auth.signOut();
  }

  // ===== USER PROFILES =====

  Future<bool> createOrUpdateProfile(String novaId, String name, {String? avatarBase64}) async {
    final user = currentUser;
    if (client == null || user == null) return false;

    final data = {
      AppConstants.colId: user.id,
      AppConstants.colNovaId: novaId,
      AppConstants.colName: name,
      AppConstants.colDisplayName: name,
      AppConstants.colUpdatedAt: DateTime.now().toIso8601String(),
    };
    if (avatarBase64 != null && avatarBase64.isNotEmpty) {
      data[AppConstants.colAvatarUrl] = avatarBase64;
    }

    final result = await _withTableFallback(
      AppConstants.tableProfiles,
      AppConstants.tableUsers,
      (builder) => builder.upsert(data),
      logContext: 'createOrUpdateProfile',
    );
    return result != null;
  }

  Future<Map<String, dynamic>?> getUserProfile(String novaId) async {
    return _withTableFallback(
      AppConstants.tableProfiles,
      AppConstants.tableUsers,
      (builder) => builder.select().eq(AppConstants.colNovaId, novaId).single(),
      logContext: 'getUserProfile',
    );
  }

  Future<Map<String, dynamic>?> getUserProfileByAuthId(String authId) async {
    return _withTableFallback(
      AppConstants.tableProfiles,
      AppConstants.tableUsers,
      (builder) => builder.select().eq(AppConstants.colId, authId).single(),
      logContext: 'getUserProfileByAuthId',
    );
  }

  Future<void> updateUserProfile(Map<String, dynamic> data) async {
    final user = currentUser;
    if (client == null || user == null) return;

    data[AppConstants.colUpdatedAt] = DateTime.now().toIso8601String();
    await _withTableFallback(
      AppConstants.tableProfiles,
      AppConstants.tableUsers,
      (builder) => builder.update(data).eq(AppConstants.colId, user.id),
      logContext: 'updateUserProfile',
    );
  }

  // ===== PUBLIC KEY MANAGEMENT =====

  Future<String?> getRemotePublicKey(String novaId) async {
    return _withTableFallback(
      AppConstants.tableProfiles,
      AppConstants.tableUsers,
      (builder) => builder.select(AppConstants.colPublicKey).eq(AppConstants.colNovaId, novaId).single(),
      logContext: 'getRemotePublicKey',
    ).then((r) => r?[AppConstants.colPublicKey] as String?);
  }

  Future<void> updatePublicKey(String publicKey) async {
    final user = currentUser;
    if (client == null || user == null) return;

    await _withTableFallback(
      AppConstants.tableProfiles,
      AppConstants.tableUsers,
      (builder) => builder.upsert({
        AppConstants.colId: user.id,
        AppConstants.colPublicKey: publicKey,
        AppConstants.colUpdatedAt: DateTime.now().toIso8601String(),
      }, onConflict: AppConstants.colId),
      logContext: 'updatePublicKey',
    );
  }

  // ===== MESSAGES =====

  Future<void> sendMessage(Map<String, dynamic> messageData) async {
    final c = client;
    if (c == null) return;
    try {
      await c.from(AppConstants.tableMessages).insert(messageData);
    } catch (e) {
      LoggerService.error('Error sending message', error: e, tag: 'Supabase');
      rethrow;
    }
  }

  Stream<List<Map<String, dynamic>>> watchMessages(String chatId) {
    final c = client;
    if (c == null) return const Stream.empty();
    return c
        .from(AppConstants.tableMessages)
        .stream(primaryKey: [AppConstants.colId])
        .eq('chat_id', chatId)
        .order('timestamp', ascending: true);
  }

  // ===== CONTACTS =====

  Future<void> saveContact(Map<String, dynamic> contactData) async {
    await client?.from(AppConstants.tableContacts).upsert(contactData);
  }

  Future<List<Map<String, dynamic>>> getContacts(String userNovaId) async {
    final c = client;
    if (c == null) return [];
    try {
      return await c.from(AppConstants.tableContacts).select().eq('user_nova_id', userNovaId);
    } catch (e) {
      LoggerService.error('Error getting contacts', error: e, tag: 'Supabase');
      return [];
    }
  }

  // ===== USER SEARCH (with input sanitization) =====

  Future<List<Map<String, dynamic>>> searchUsers(String query) async {
    final c = client;
    if (c == null || query.isEmpty) return [];

    // Sanitize: escape SQL wildcards % and _
    final sanitized = query
        .toUpperCase()
        .replaceAll(RegExp(r'NOVA-?'), '')
        .trim()
        .replaceAll('%', '')
        .replaceAll('_', '');

    if (sanitized.isEmpty) return [];

    final results = await _withTableFallback(
      AppConstants.tableProfiles,
      AppConstants.tableUsers,
      (builder) => builder.select().or(
        'name.ilike.%$sanitized%,${AppConstants.colNovaId}.ilike.%$sanitized%',
      ),
      logContext: 'searchUsers',
    );
    return results ?? [];
  }

  Future<Map<String, dynamic>?> getUserByNovaId(String novaId) async {
    return _withTableFallback(
      AppConstants.tableProfiles,
      AppConstants.tableUsers,
      (builder) => builder.select().eq(AppConstants.colNovaId, novaId).single(),
      logContext: 'getUserByNovaId',
    );
  }

  // ===== FCM TOKENS =====

  Future<void> saveFcmToken(String token) async {
    final user = currentUser;
    if (client == null || user == null) return;

    await _withTableFallback(
      AppConstants.tableProfiles,
      AppConstants.tableUsers,
      (builder) => builder.update({
        'fcm_token': token,
        AppConstants.colUpdatedAt: DateTime.now().toIso8601String(),
      }).eq(AppConstants.colId, user.id),
      logContext: 'saveFcmToken',
    );
  }

  Future<String?> getFcmToken(String novaId) async {
    return _withTableFallback(
      AppConstants.tableProfiles,
      AppConstants.tableUsers,
      (builder) => builder.select('fcm_token').eq(AppConstants.colNovaId, novaId).single(),
      logContext: 'getFcmToken',
    ).then((r) => r?['fcm_token'] as String?);
  }
}

final supabaseServiceProvider = Provider((ref) => SupabaseService());
final supabaseClientProvider = Provider<SupabaseClient?>((ref) => ref.watch(supabaseServiceProvider).client);
