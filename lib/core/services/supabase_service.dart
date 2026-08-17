import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'logger_service.dart';

class SupabaseService {
  static late final String supabaseUrl;
  static late final String supabaseAnonKey;
  static bool _isInitialized = false;

  static Future<void> initialize() async {
    supabaseUrl = dotenv.env['SUPABASE_URL'] ?? '';
    supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'] ?? '';

    LoggerService.info('Supabase URL: $supabaseUrl', tag: 'Supabase');
    LoggerService.info('Supabase Anon Key: ${supabaseAnonKey.isNotEmpty ? "SET" : "NOT SET"}', tag: 'Supabase');

    if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
      throw Exception('SUPABASE_URL and SUPABASE_ANON_KEY must be set in .env file');
    }

    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
      // ignore: deprecated_member_use
    );
    _isInitialized = true;
    LoggerService.info('Supabase initialized successfully', tag: 'Supabase');
  }

  SupabaseClient? get client {
    if (!_isInitialized) {
      LoggerService.warning('Supabase is not initialized. Cannot access client.', tag: 'Supabase');
      return null;
    }
    return Supabase.instance.client;
  }

  // ===== AUTHENTICATION (Sistema Anónimo) =====

  // Crear sesión anónima (sin email/contraseña)
  // Si ya hay sesión activa, la reutiliza en vez de crear una nueva.
  Future<AuthResponse?> createAnonymousSession() async {
    final clientInstance = client;
    if (clientInstance == null) {
      LoggerService.error('Cannot create anonymous session: Supabase is not initialized.', tag: 'Supabase');
      return null;
    }
    if (clientInstance.auth.currentUser != null) {
      LoggerService.info('User already authenticated: ${clientInstance.auth.currentUser?.id}', tag: 'Supabase');
      return null;
    }
    LoggerService.info('Creating anonymous session...', tag: 'Supabase');
    final response = await clientInstance.auth.signInAnonymously();
    LoggerService.info('Anonymous session created: ${response.user?.id}', tag: 'Supabase');
    return response;
  }

  // Sign out
  Future<void> signOut() async {
    final clientInstance = client;
    if (clientInstance != null) {
      await clientInstance.auth.signOut();
    }
  }

  // Get current user
  User? get currentUser {
    final clientInstance = client;
    if (clientInstance == null) return null;
    return clientInstance.auth.currentUser;
  }

  // ===== USER PROFILES =====
  
  /// Creates or updates a user profile in Supabase.
  /// Also uploads an avatar if [avatarBase64] is provided.
  /// Tries both 'profiles' and 'users' tables to support both schemas.
  Future<bool> createOrUpdateProfile(String novaId, String name, {String? avatarBase64}) async {
    final clientInstance = client;
    final user = currentUser;
    LoggerService.debug('createOrUpdateProfile - Nova ID: $novaId, Name: $name', tag: 'Supabase');
    LoggerService.debug('Current user ID: ${user?.id}, Client is ${clientInstance == null ? "null" : "initialized"}', tag: 'Supabase');

    if (clientInstance == null) {
      LoggerService.error('Cannot create profile - Supabase is not initialized.', tag: 'Supabase');
      return false;
    }

    if (user == null) {
      LoggerService.error('Cannot create profile - User is not authenticated.', tag: 'Supabase');
      return false;
    }
    try {
      final updateData = {
        'id': user.id,
        'nova_id': novaId,
        'name': name,
        'display_name': name,
        'updated_at': DateTime.now().toIso8601String(),
      };

      if (avatarBase64 != null && avatarBase64.isNotEmpty) {
        updateData['avatar_url'] = avatarBase64;
        LoggerService.debug('Avatar included: ${avatarBase64.length} bytes', tag: 'Supabase');
      }

      try {
        await clientInstance.from('profiles').upsert(updateData);
        LoggerService.info('Profile saved to profiles table', tag: 'Supabase');
        return true;
      } catch (e) {
        LoggerService.debug('Failed to save to profiles table, trying users table', tag: 'Supabase');
        try {
          await clientInstance.from('users').upsert(updateData);
          LoggerService.info('Profile saved to users table', tag: 'Supabase');
          return true;
        } catch (e2) {
          LoggerService.error('Failed to save to users table', error: e2, tag: 'Supabase');
          return false;
        }
      }
    } catch (e) {
      LoggerService.error('Exception in createOrUpdateProfile', error: e, tag: 'Supabase');
      return false;
    }
  }

  Future<Map<String, dynamic>?> getUserProfile(String novaId) async {
    final clientInstance = client;
    if (clientInstance == null) return null;
    try {
      try {
        final response = await clientInstance.from('profiles').select().eq('nova_id', novaId).single();
        return response;
      } catch (e) {
        LoggerService.debug('Failed to get from profiles table, trying users table', tag: 'Supabase');
        try {
          final response = await clientInstance.from('users').select().eq('nova_id', novaId).single();
          return response;
        } catch (e2) {
          LoggerService.debug('Error getting user profile', error: e2, tag: 'Supabase');
          return null;
        }
      }
    } catch (e) {
      LoggerService.error('Error getting user profile', error: e, tag: 'Supabase');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getUserProfileByAuthId(String authId) async {
    final clientInstance = client;
    if (clientInstance == null) return null;
    try {
      try {
        final response = await clientInstance.from('profiles').select().eq('id', authId).single();
        return response;
      } catch (e) {
        LoggerService.debug('Failed to get from profiles table, trying users table', tag: 'Supabase');
        try {
          final response = await clientInstance.from('users').select().eq('id', authId).single();
          return response;
        } catch (e2) {
          LoggerService.debug('Error getting user profile by auth id', error: e2, tag: 'Supabase');
          return null;
        }
      }
    } catch (e) {
      LoggerService.error('Error getting user profile by auth id', error: e, tag: 'Supabase');
      return null;
    }
  }

  Future<void> updateUserProfile(Map<String, dynamic> data) async {
    final clientInstance = client;
    final user = currentUser;
    if (clientInstance != null && user != null) {
      try {
        await clientInstance.from('profiles').update({
          ...data,
          'updated_at': DateTime.now().toIso8601String(),
        }).eq('id', user.id);
      } catch (e) {
        LoggerService.debug('Failed to update profiles table, trying users table', tag: 'Supabase');
        try {
          await clientInstance.from('users').update({
            ...data,
            'updated_at': DateTime.now().toIso8601String(),
          }).eq('id', user.id);
        } catch (e2) {
          LoggerService.error('Error updating user profile', error: e2, tag: 'Supabase');
        }
      }
    }
  }

  // ===== PUBLIC KEY MANAGEMENT =====

  Future<String?> getRemotePublicKey(String novaId) async {
    final clientInstance = client;
    if (clientInstance == null) return null;
    try {
      try {
        final response = await clientInstance.from('profiles').select('public_key').eq('nova_id', novaId).single();
        return response['public_key'] as String?;
      } catch (e) {
        LoggerService.debug('Failed to get public key from profiles table, trying users table', tag: 'Supabase');
        try {
          final response = await clientInstance.from('users').select('public_key').eq('nova_id', novaId).single();
          return response['public_key'] as String?;
        } catch (e2) {
          LoggerService.debug('Error getting public key', error: e2, tag: 'Supabase');
          return null;
        }
      }
    } catch (e) {
      LoggerService.error('Error getting public key', error: e, tag: 'Supabase');
      return null;
    }
  }

  Future<void> updatePublicKey(String publicKey) async {
    final clientInstance = client;
    final user = currentUser;
    LoggerService.trace('updatePublicKey called for user: ${user?.id}', tag: 'Supabase');
    
    if (clientInstance != null && user != null) {
      try {
        await clientInstance.from('profiles').upsert({
          'id': user.id,
          'public_key': publicKey,
          'updated_at': DateTime.now().toIso8601String(),
        }, onConflict: 'id');
        LoggerService.info('Public key updated in profiles table', tag: 'Supabase');
      } catch (e) {
        LoggerService.debug('Failed to update public key in profiles table, trying users table', tag: 'Supabase');
        try {
          await clientInstance.from('users').upsert({
            'id': user.id,
            'public_key': publicKey,
            'updated_at': DateTime.now().toIso8601String(),
          }, onConflict: 'id');
          LoggerService.info('Public key updated in users table', tag: 'Supabase');
        } catch (e2) {
          LoggerService.error('Error updating public key', error: e2, tag: 'Supabase');
        }
      }
    } else {
      LoggerService.warning('Cannot update public key: client or user is null', tag: 'Supabase');
    }
  }

  // ===== MESSAGES =====

  Future<void> sendMessage(Map<String, dynamic> messageData) async {
    final clientInstance = client;
    if (clientInstance == null) return;
    try {
      await clientInstance.from('messages').insert(messageData);
    } catch (e) {
      LoggerService.error('Error sending message', error: e, tag: 'Supabase');
      rethrow;
    }
  }

  Stream<List<Map<String, dynamic>>> watchMessages(String chatId) {
    final clientInstance = client;
    if (clientInstance == null) {
      return const Stream.empty();
    }
    return clientInstance
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('chat_id', chatId)
        .order('timestamp', ascending: true);
  }

  // ===== CONTACTS =====

  Future<void> saveContact(Map<String, dynamic> contactData) async {
    final clientInstance = client;
    if (clientInstance == null) return;
    try {
      await clientInstance.from('contacts').upsert(contactData);
    } catch (e) {
      LoggerService.error('Error saving contact', error: e, tag: 'Supabase');
    }
  }

  Future<List<Map<String, dynamic>>> getContacts(String userNovaId) async {
    final clientInstance = client;
    if (clientInstance == null) return [];
    try {
      final response = await clientInstance.from('contacts').select().eq('user_nova_id', userNovaId);
      return response;
    } catch (e) {
      LoggerService.error('Error getting contacts', error: e, tag: 'Supabase');
      return [];
    }
  }

  // ===== USER SEARCH =====

  /// Searches users by the 8-char ID (without NOVA- prefix), name, or display_name.
  /// nova_id format in DB: NOVA-XXXXXXXX
  /// If [query] looks like the 8-char suffix, construct full nova_id for lookup.
  Future<List<Map<String, dynamic>>> searchUsers(String query) async {
    final clientInstance = client;
    if (clientInstance == null) return [];
    if (query.isEmpty) return [];
    try {
      final normalized = query.toUpperCase().replaceAll('NOVA-', '').replaceAll('NOVA', '').trim();
      List<Map<String, dynamic>> results = [];
      try {
        final response = await clientInstance
            .from('profiles')
            .select()
            .or('name.ilike.%$normalized%,nova_id.ilike.%$normalized%');
        results.addAll(List<Map<String, dynamic>>.from(response));
      } catch (_) {
        LoggerService.debug('searchUsers: profiles table failed, trying users table', tag: 'Supabase');
      }
      if (results.isEmpty) {
        try {
          final response = await clientInstance
              .from('users')
              .select()
              .or('name.ilike.%$normalized%,nova_id.ilike.%$normalized%');
          results.addAll(List<Map<String, dynamic>>.from(response));
        } catch (_) {
          LoggerService.debug('searchUsers: users table also failed', tag: 'Supabase');
        }
      }
      return results;
    } catch (e) {
      LoggerService.error('Error searching users', error: e, tag: 'Supabase');
      return [];
    }
  }

  Future<Map<String, dynamic>?> getUserByNovaId(String novaId) async {
    final clientInstance = client;
    if (clientInstance == null) return null;
    try {
      try {
        final response = await clientInstance.from('profiles').select().eq('nova_id', novaId).single();
        return response;
      } catch (e) {
        LoggerService.debug('Failed to get user from profiles table, trying users table', tag: 'Supabase');
        try {
          final response = await clientInstance.from('users').select().eq('nova_id', novaId).single();
          return response;
        } catch (e2) {
          LoggerService.debug('Error getting user by nova_id', error: e2, tag: 'Supabase');
          return null;
        }
      }
    } catch (e) {
      LoggerService.error('Error getting user by nova_id', error: e, tag: 'Supabase');
      return null;
    }
  }

  // ===== FCM TOKENS =====

  Future<void> saveFcmToken(String token) async {
    final clientInstance = client;
    final user = currentUser;
    if (clientInstance == null || user == null) return;
    try {
      try {
        await clientInstance.from('profiles').update({
          'fcm_token': token,
          'updated_at': DateTime.now().toIso8601String(),
        }).eq('id', user.id);
        LoggerService.info('FCM token saved for user ${user.id} in profiles table', tag: 'Supabase');
      } catch (e) {
        LoggerService.debug('Failed to save FCM token in profiles table, trying users table', tag: 'Supabase');
        try {
          await clientInstance.from('users').update({
            'fcm_token': token,
            'updated_at': DateTime.now().toIso8601String(),
          }).eq('id', user.id);
          LoggerService.info('FCM token saved for user ${user.id} in users table', tag: 'Supabase');
        } catch (e2) {
          LoggerService.warning('Error saving FCM token (non-critical)', error: e2, tag: 'Supabase');
        }
      }
    } catch (e) {
      LoggerService.warning('Error saving FCM token (non-critical)', error: e, tag: 'Supabase');
    }
  }

  Future<String?> getFcmToken(String novaId) async {
    final clientInstance = client;
    if (clientInstance == null) return null;
    try {
      try {
        final response = await clientInstance
            .from('profiles')
            .select('fcm_token')
            .eq('nova_id', novaId)
            .single();
        return response['fcm_token'] as String?;
      } catch (e) {
        LoggerService.debug('Failed to get FCM token from profiles table, trying users table', tag: 'Supabase');
        try {
          final response = await clientInstance
              .from('users')
              .select('fcm_token')
              .eq('nova_id', novaId)
              .single();
          return response['fcm_token'] as String?;
        } catch (e2) {
          LoggerService.debug('Error getting FCM token', error: e2, tag: 'Supabase');
          return null;
        }
      }
    } catch (e) {
      LoggerService.error('Error getting FCM token', error: e, tag: 'Supabase');
      return null;
    }
  }

}

final supabaseServiceProvider = Provider((ref) => SupabaseService());
final supabaseClientProvider = Provider<SupabaseClient?>((ref) => ref.watch(supabaseServiceProvider).client);
