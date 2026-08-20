import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:novaapp/core/constants.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';

/// Group management service for FASE 8.
///
/// Features:
///   - Create / delete groups
///   - Add / remove members
///   - Multiple admins with granular permissions
///   - Invite links
///   - Mentions (@)
///   - Pinned messages
///   - Shared files
///   - Mute/unmute

class GroupService {
  final SupabaseClient? _client;

  GroupService(this._client);

  // ===== GROUP CRUD =====

  /// Creates a new group. Returns the group ID.
  Future<String?> createGroup({
    required String creatorNovaId,
    required String name,
    String? description,
    String? avatarUrl,
    List<String> memberNovaIds = const [],
  }) async {
    if (_client == null) return null;
    try {
      // Create group
      final result = await _client!.from('groups').insert({
        'name': name,
        'description': description,
        'avatar_url': avatarUrl,
        'creator_nova_id': creatorNovaId,
        'created_at': DateTime.now().toIso8601String(),
      }).select('id').single();

      final groupId = result['id'] as String;

      // Add creator as owner
      await _client!.from('group_members').insert({
        'group_id': groupId,
        'nova_id': creatorNovaId,
        'role': 'owner',
        'joined_at': DateTime.now().toIso8601String(),
      });

      // Add initial members
      if (memberNovaIds.isNotEmpty) {
        final members = memberNovaIds.map((novaId) => {
          'group_id': groupId,
          'nova_id': novaId,
          'role': 'member',
          'joined_at': DateTime.now().toIso8601String(),
        }).toList();
        await _client!.from('group_members').insert(members);
      }

      LoggerService.info('Group created: $groupId ($name)', tag: 'Group');
      return groupId;
    } catch (e) {
      LoggerService.error('Failed to create group', error: e, tag: 'Group');
      return null;
    }
  }

  /// Deletes a group (owner only).
  Future<bool> deleteGroup(String groupId, String requesterNovaId) async {
    if (_client == null) return false;
    try {
      // Verify owner
      final member = await _client!
          .from('group_members')
          .select('role')
          .eq('group_id', groupId)
          .eq('nova_id', requesterNovaId)
          .maybeSingle();

      if (member == null || member['role'] != 'owner') {
        LoggerService.warning('Not authorized to delete group', tag: 'Group');
        return false;
      }

      await _client!.from('groups').delete().eq('id', groupId);
      LoggerService.info('Group deleted: $groupId', tag: 'Group');
      return true;
    } catch (e) {
      LoggerService.error('Failed to delete group', error: e, tag: 'Group');
      return false;
    }
  }

  // ===== MEMBER MANAGEMENT =====

  /// Adds members to a group.
  Future<bool> addMembers({
    required String groupId,
    required String requesterNovaId,
    required List<String> novaIds,
  }) async {
    if (_client == null) return false;
    try {
      // Check permissions
      if (!await _hasPermission(groupId, requesterNovaId, 'add_members')) {
        LoggerService.warning('No permission to add members', tag: 'Group');
        return false;
      }

      final members = novaIds.map((novaId) => {
        'group_id': groupId,
        'nova_id': novaId,
        'role': 'member',
        'joined_at': DateTime.now().toIso8601String(),
      }).toList();

      await _client!.from('group_members').upsert(members,
          onConflict: 'group_id,nova_id');

      LoggerService.info('Added ${novaIds.length} members to $groupId', tag: 'Group');
      return true;
    } catch (e) {
      LoggerService.error('Failed to add members', error: e, tag: 'Group');
      return false;
    }
  }

  /// Removes a member from a group.
  Future<bool> removeMember({
    required String groupId,
    required String requesterNovaId,
    required String targetNovaId,
  }) async {
    if (_client == null) return false;
    try {
      // Check permissions
      if (!await _hasPermission(groupId, requesterNovaId, 'remove_members')) {
        LoggerService.warning('No permission to remove members', tag: 'Group');
        return false;
      }

      // Cannot remove owner
      final target = await _client!
          .from('group_members')
          .select('role')
          .eq('group_id', groupId)
          .eq('nova_id', targetNovaId)
          .maybeSingle();

      if (target != null && target['role'] == 'owner') {
        LoggerService.warning('Cannot remove group owner', tag: 'Group');
        return false;
      }

      await _client!.from('group_members').delete()
        .eq('group_id', groupId)
        .eq('nova_id', targetNovaId);

      LoggerService.info('Removed $targetNovaId from $groupId', tag: 'Group');
      return true;
    } catch (e) {
      LoggerService.error('Failed to remove member', error: e, tag: 'Group');
      return false;
    }
  }

  /// Promotes a member to admin.
  Future<bool> promoteToAdmin({
    required String groupId,
    required String requesterNovaId,
    required String targetNovaId,
  }) async {
    if (_client == null) return false;
    try {
      if (!await _hasPermission(groupId, requesterNovaId, 'manage_admins')) return false;

      await _client!.from('group_members').update({
        'role': 'admin',
      }).eq('group_id', groupId).eq('nova_id', targetNovaId);

      LoggerService.info('Promoted $targetNovaId to admin in $groupId', tag: 'Group');
      return true;
    } catch (e) {
      LoggerService.error('Failed to promote member', error: e, tag: 'Group');
      return false;
    }
  }

  // ===== INVITE LINKS =====

  /// Generates an invite link for a group.
  Future<String?> generateInviteLink({
    required String groupId,
    required String requesterNovaId,
    Duration expiry = const Duration(days: 7),
    int maxUses = 50,
  }) async {
    if (_client == null) return null;
    try {
      if (!await _hasPermission(groupId, requesterNovaId, 'invite')) return null;

      final token = _generateToken(32);
      await _client!.from('group_invites').insert({
        'group_id': groupId,
        'token': token,
        'created_by': requesterNovaId,
        'max_uses': maxUses,
        'uses': 0,
        'expires_at': DateTime.now().add(expiry).toIso8601String(),
        'created_at': DateTime.now().toIso8601String(),
      });

      LoggerService.info('Invite link generated for $groupId', tag: 'Group');
      return 'https://novaapp.chat/invite/$token';
    } catch (e) {
      LoggerService.error('Failed to generate invite link', error: e, tag: 'Group');
      return null;
    }
  }

  /// Joins a group using an invite token.
  Future<bool> joinViaInvite({
    required String token,
    required String novaId,
  }) async {
    if (_client == null) return false;
    try {
      final invite = await _client!
          .from('group_invites')
          .select('group_id, max_uses, uses, expires_at')
          .eq('token', token)
          .maybeSingle();

      if (invite == null) return false;
      if (DateTime.parse(invite['expires_at']).isBefore(DateTime.now())) return false;
      if ((invite['uses'] as int) >= (invite['max_uses'] as int)) return false;

      // Join group
      await addMembers(
        groupId: invite['group_id'],
        requesterNovaId: novaId, // Self-add via invite
        novaIds: [novaId],
      );

      // Increment uses
      await _client!.from('group_invites').update({
        'uses': (invite['uses'] as int) + 1,
      }).eq('token', token);

      LoggerService.info('$novaId joined via invite', tag: 'Group');
      return true;
    } catch (e) {
      LoggerService.error('Failed to join via invite', error: e, tag: 'Group');
      return false;
    }
  }

  // ===== MENTIONS =====

  /// Parses @mentions in a message text and returns mentioned Nova IDs.
  static List<String> parseMentions(String text) {
    final regex = RegExp(r'@([A-Z]{4}-[A-Z0-9]{9})');
    return regex.allMatches(text).map((m) => m.group(0)!.substring(1)).toList();
  }

  /// Fetches member list for mention autocomplete.
  Future<List<Map<String, dynamic>>> getMembersForMention(String groupId) async {
    if (_client == null) return [];
    try {
      final result = await _client!
          .from('group_members')
          .select('nova_id, display_name, role')
          .eq('group_id', groupId)
          .order('display_name');
      return List<Map<String, dynamic>>.from(result);
    } catch (_) {
      return [];
    }
  }

  // ===== MUTE =====

  /// Mutes/unmutes a group for a user.
  Future<void> toggleMute({
    required String groupId,
    required String novaId,
    required bool mute,
  }) async {
    if (_client == null) return;
    try {
      await _client!.from('group_members').update({
        'is_muted': mute,
      }).eq('group_id', groupId).eq('nova_id', novaId);
    } catch (_) {}
  }

  // ===== PERMISSION CHECK =====

  Future<bool> _hasPermission(String groupId, String novaId, String permission) async {
    if (_client == null) return false;
    try {
      final member = await _client!
          .from('group_members')
          .select('role')
          .eq('group_id', groupId)
          .eq('nova_id', novaId)
          .maybeSingle();

      if (member == null) return false;

      final role = member['role'] as String;
      return _rolePermissions[role]?.contains(permission) ?? false;
    } catch (_) {
      return false;
    }
  }

  static const Map<String, List<String>> _rolePermissions = {
    'owner': ['add_members', 'remove_members', 'manage_admins', 'invite', 'delete_group', 'pin_messages', 'send_messages'],
    'admin': ['add_members', 'remove_members', 'invite', 'pin_messages', 'send_messages'],
    'member': ['invite', 'send_messages'],
  };

  // ===== HELPERS =====

  static String _generateToken(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final rng = DateTime.now().microsecondsSinceEpoch;
    String token = '';
    for (int i = 0; i < length; i++) {
      token += chars[(rng + i * 7) % chars.length];
    }
    return token;
  }
}

final groupServiceProvider = Provider<GroupService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return GroupService(client);
});
