import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/services/supabase_service.dart';

class ModerationService {
  final SupabaseClient? _client;
  final bool _isInitialized;

  ModerationService(this._client) : _isInitialized = true;
  
  ModerationService._uninitialized() 
      : _client = null, 
        _isInitialized = false;

  /// Report a user for inappropriate behavior
  Future<void> reportUser({
    required String reporterId,
    required String reportedId,
    required String reason,
  }) async {
    if (!_isInitialized || _client == null) {
      throw Exception('Supabase client is not initialized');
    }
    try {
      await _client.from('reports').insert({
        'reporter_id': reporterId,
        'reported_id': reportedId,
        'reason': reason,
      });
    } catch (e) {
      throw Exception('Error reporting user: $e');
    }
  }

  /// Block a user
  Future<void> blockUser({
    required String blockerId,
    required String blockedId,
  }) async {
    if (!_isInitialized || _client == null) {
      throw Exception('Supabase client is not initialized');
    }
    try {
      await _client.from('blocked_users').insert({
        'blocker_id': blockerId,
        'blocked_id': blockedId,
      });
    } catch (e) {
      throw Exception('Error blocking user: $e');
    }
  }

  /// Unblock a user
  Future<void> unblockUser({
    required String blockerId,
    required String blockedId,
  }) async {
    if (!_isInitialized || _client == null) {
      throw Exception('Supabase client is not initialized');
    }
    try {
      await _client
          .from('blocked_users')
          .delete()
          .eq('blocker_id', blockerId)
          .eq('blocked_id', blockedId);
    } catch (e) {
      throw Exception('Error unblocking user: $e');
    }
  }

  /// Check if a user is blocked
  Future<bool> isUserBlocked({
    required String blockerId,
    required String blockedId,
  }) async {
    if (!_isInitialized || _client == null) {
      return false;
    }
    try {
      final response = await _client
          .from('blocked_users')
          .select()
          .eq('blocker_id', blockerId)
          .eq('blocked_id', blockedId)
          .maybeSingle();
      return response != null;
    } catch (e) {
      return false;
    }
  }

  /// Get list of blocked users
  Future<List<Map<String, dynamic>>> getBlockedUsers(String blockerId) async {
    if (!_isInitialized || _client == null) {
      return [];
    }
    try {
      final response = await _client
          .from('blocked_users')
          .select('''
            blocked_id,
            blocked_users!inner (
              id,
              nova_id,
              display_name,
              avatar_url
            )
          ''')
          .eq('blocker_id', blockerId);
      return response;
    } catch (e) {
      throw Exception('Error fetching blocked users: $e');
    }
  }

  /// Check if a user has been reported by the current user
  Future<bool> hasUserBeenReported({
    required String reporterId,
    required String reportedId,
  }) async {
    if (!_isInitialized || _client == null) {
      return false;
    }
    try {
      final response = await _client
          .from('reports')
          .select()
          .eq('reporter_id', reporterId)
          .eq('reported_id', reportedId)
          .maybeSingle();
      return response != null;
    } catch (e) {
      return false;
    }
  }

  /// Get user's report count
  Future<int> getUserReportCount(String userId) async {
    if (!_isInitialized || _client == null) {
      return 0;
    }
    try {
      final response = await _client
          .from('profiles')
          .select('reports_count')
          .eq('id', userId)
          .single();
      return response['reports_count'] as int? ?? 0;
    } catch (e) {
      return 0;
    }
  }

  /// Check if a user is shadowbanned
  Future<bool> isUserShadowbanned(String userId) async {
    if (!_isInitialized || _client == null) {
      return false;
    }
    try {
      final response = await _client
          .from('profiles')
          .select('is_shadowbanned')
          .eq('id', userId)
          .single();
      return response['is_shadowbanned'] as bool? ?? false;
    } catch (e) {
      return false;
    }
  }
}

final moderationServiceProvider = Provider<ModerationService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) {
    // Return a service that will throw on actual method calls
    // This allows the app to build without crashing during initialization
    return ModerationService._uninitialized();
  }
  return ModerationService(client);
});
