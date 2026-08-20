import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:novaapp/core/constants.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';

/// Privacy settings for FASE 13.
///
/// Granular controls:
///   - Who can find me (search visibility)
///   - Who can message me
///   - Who can call me
///   - Who can add me to groups
///   - Presence visibility (online/last seen)
///   - Read receipts
///   - Typing indicators
///   - Default message TTL

enum PrivacyLevel { everyone, contacts, nobody }

class PrivacyService {
  final SupabaseClient? _client;

  PrivacyService(this._client);

  // ===== GET SETTINGS =====

  /// Fetches all privacy settings for a user.
  Future<Map<String, dynamic>> getPrivacySettings(String novaId) async {
    if (_client == null) return _defaultSettings();
    try {
      final result = await _client!.from('user_settings')
          .select('*')
          .eq('nova_id', novaId)
          .maybeSingle();

      if (result == null) return _defaultSettings();
      return result;
    } catch (e) {
      LoggerService.error('Failed to fetch privacy settings', error: e, tag: 'Privacy');
      return _defaultSettings();
    }
  }

  Map<String, dynamic> _defaultSettings() {
    return {
      'nova_id': '',
      'findability': 'everyone', // everyone, contacts, nobody
      'who_can_message': 'everyone',
      'who_can_call': 'everyone',
      'who_can_add_to_groups': 'everyone',
      'show_online_status': true,
      'show_last_seen': true,
      'read_receipts': true,
      'typing_indicators': true,
      'default_message_ttl': null, // null = no expiry
      'blocked_users': [],
    };
  }

  // ===== UPDATE SETTINGS =====

  /// Updates a single privacy setting.
  Future<bool> updateSetting({
    required String novaId,
    required String key,
    required dynamic value,
  }) async {
    if (_client == null) return false;
    try {
      await _client!.from('user_settings').upsert({
        'nova_id': novaId,
        key: value,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'nova_id');

      LoggerService.info('Privacy setting updated: $key = $value', tag: 'Privacy');
      return true;
    } catch (e) {
      LoggerService.error('Failed to update privacy setting', error: e, tag: 'Privacy');
      return false;
    }
  }

  /// Updates multiple settings at once.
  Future<bool> updateMultipleSettings({
    required String novaId,
    required Map<String, dynamic> settings,
  }) async {
    if (_client == null) return false;
    try {
      final update = Map<String, dynamic>.from(settings);
      update['nova_id'] = novaId;
      update['updated_at'] = DateTime.now().toIso8601String();

      await _client!.from('user_settings').upsert(update, onConflict: 'nova_id');

      LoggerService.info('Privacy settings updated: ${settings.keys.join(", ")}', tag: 'Privacy');
      return true;
    } catch (e) {
      LoggerService.error('Failed to update privacy settings', error: e, tag: 'Privacy');
      return false;
    }
  }

  // ===== VISIBILITY CHECKS =====

  /// Checks if a user can be found via search.
  Future<bool> canBeFound(String targetNovaId, String requesterNovaId) async {
    final settings = await getPrivacySettings(targetNovaId);
    final level = settings['findability'] as String? ?? 'everyone';

    if (level == 'everyone') return true;
    if (level == 'nobody') return false;
    if (level == 'contacts') {
      return await _areContacts(targetNovaId, requesterNovaId);
    }
    return true;
  }

  /// Checks if a user can be messaged.
  Future<bool> canBeMessaged(String targetNovaId, String requesterNovaId) async {
    final settings = await getPrivacySettings(targetNovaId);
    final level = settings['who_can_message'] as String? ?? 'everyone';

    if (level == 'everyone') return true;
    if (level == 'nobody') return false;
    if (level == 'contacts') {
      return await _areContacts(targetNovaId, requesterNovaId);
    }
    return true;
  }

  /// Checks if a user can be called.
  Future<bool> canBeCalled(String targetNovaId, String requesterNovaId) async {
    final settings = await getPrivacySettings(targetNovaId);
    final level = settings['who_can_call'] as String? ?? 'everyone';

    if (level == 'everyone') return true;
    if (level == 'nobody') return false;
    if (level == 'contacts') {
      return await _areContacts(targetNovaId, requesterNovaId);
    }
    return true;
  }

  /// Checks if a user can be added to groups.
  Future<bool> canBeAddedToGroups(String targetNovaId, String requesterNovaId) async {
    final settings = await getPrivacySettings(targetNovaId);
    final level = settings['who_can_add_to_groups'] as String? ?? 'everyone';

    if (level == 'everyone') return true;
    if (level == 'nobody') return false;
    if (level == 'contacts') {
      return await _areContacts(targetNovaId, requesterNovaId);
    }
    return true;
  }

  /// Returns true if the user shows online status.
  Future<bool> showsOnlineStatus(String novaId) async {
    final settings = await getPrivacySettings(novaId);
    return settings['show_online_status'] as bool? ?? true;
  }

  /// Returns true if the user shows last seen.
  Future<bool> showsLastSeen(String novaId) async {
    final settings = await getPrivacySettings(novaId);
    return settings['show_last_seen'] as bool? ?? true;
  }

  /// Returns true if read receipts are enabled.
  Future<bool> hasReadReceipts(String novaId) async {
    final settings = await getPrivacySettings(novaId);
    return settings['read_receipts'] as bool? ?? true;
  }

  /// Returns true if typing indicators are enabled.
  Future<bool> hasTypingIndicators(String novaId) async {
    final settings = await getPrivacySettings(novaId);
    return settings['typing_indicators'] as bool? ?? true;
  }

  /// Returns the default message TTL for a user.
  Future<int?> getDefaultMessageTTL(String novaId) async {
    final settings = await getPrivacySettings(novaId);
    return settings['default_message_ttl'] as int?;
  }

  // ===== HELPERS =====

  Future<bool> _areContacts(String novaId1, String novaId2) async {
    if (_client == null) return false;
    try {
      final result = await _client!.from('contacts')
          .select('id')
          .eq('user_nova_id', novaId1)
          .eq('contact_id', novaId2)
          .maybeSingle();
      return result != null;
    } catch (_) {
      return false;
    }
  }
}

final privacyServiceProvider = Provider<PrivacyService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return PrivacyService(client);
});
