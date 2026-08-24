import 'session_registry.dart' show RegisteredSession;

/// REFERENCE implementation of server-side AUTHORIZATION.
///
/// Authentication != authorization: an authenticated device is NOT
/// automatically allowed to read any conversation, message any user, or
/// signal any peer. Every operation re-checks authorization.
///
/// The realtime server MUST call the equivalent of these checks before
/// handling each event (production mapping: Supabase membership tables with
/// RLS — see docs/SOCKET_SERVER_ARCHITECTURE.md).
enum AuthzDecision { allow, denyNotAuthenticated, denyNotAuthorized }

class AuthorizationPolicy {
  /// conversationId -> member account ids.
  final Map<String, Set<String>> _conversationMembers =
      <String, Set<String>>{};

  /// accountId -> set of account ids allowed to be contacted (contacts +
  /// mutual relationships; blocked users are absent).
  final Map<String, Set<String>> _relationships = <String, Set<String>>{};

  /// accountId -> account ids allowed to see this account's presence
  /// (privacy setting: presence is opt-in per relationship).
  final Map<String, Set<String>> _presenceAudience = <String, Set<String>>{};

  void addConversationMember(String conversationId, String accountId) {
    _conversationMembers.putIfAbsent(conversationId, () => <String>{}).add(
      accountId,
    );
  }

  void addRelationship(String a, String b) {
    _relationships.putIfAbsent(a, () => <String>{}).add(b);
    _relationships.putIfAbsent(b, () => <String>{}).add(a);
  }

  /// Marks [viewer] allowed to see [subject]'s presence.
  void allowPresence(String subject, String viewer) {
    _presenceAudience.putIfAbsent(subject, () => <String>{}).add(viewer);
  }

  /// message.send: requires an authenticated session AND conversation
  /// membership for the session's account.
  AuthzDecision canSendMessage({
    required RegisteredSession? session,
    required String conversationId,
  }) {
    if (session == null) return AuthzDecision.denyNotAuthenticated;
    final members = _conversationMembers[conversationId];
    if (members == null || !members.contains(session.accountId)) {
      return AuthzDecision.denyNotAuthorized;
    }
    return AuthzDecision.allow;
  }

  /// call.* signaling: both peers must have a relationship (contacts),
  /// neither blocked. Audio/video itself NEVER flows through Socket.IO —
  /// this only gates WebRTC signaling relay.
  AuthzDecision canSignalCall({
    required RegisteredSession? session,
    required String peerAccountId,
  }) {
    if (session == null) return AuthzDecision.denyNotAuthenticated;
    final peers = _relationships[session.accountId];
    if (peers == null || !peers.contains(peerAccountId)) {
      return AuthzDecision.denyNotAuthorized;
    }
    return AuthzDecision.allow;
  }

  /// Reading a conversation's events (sync, message.delivered/read updates,
  /// incoming fan-out): membership required.
  AuthzDecision canReadConversation({
    required RegisteredSession? session,
    required String conversationId,
  }) {
    if (session == null) return AuthzDecision.denyNotAuthenticated;
    final members = _conversationMembers[conversationId];
    if (members == null || !members.contains(session.accountId)) {
      return AuthzDecision.denyNotAuthorized;
    }
    return AuthzDecision.allow;
  }

  /// Presence: the viewer must be in the subject's privacy audience.
  /// Presence is NEVER broadcast globally.
  AuthzDecision canViewPresence({
    required RegisteredSession? session,
    required String subjectAccountId,
  }) {
    if (session == null) return AuthzDecision.denyNotAuthenticated;
    final audience = _presenceAudience[subjectAccountId];
    if (audience == null || !audience.contains(session.accountId)) {
      return AuthzDecision.denyNotAuthorized;
    }
    return AuthzDecision.allow;
  }

  /// Device management events (device.revoked fan-out, remote logout):
  /// only the same ACCOUNT may manage its devices.
  AuthzDecision canManageDevices({
    required RegisteredSession? session,
    required String targetAccountId,
  }) {
    if (session == null) return AuthzDecision.denyNotAuthenticated;
    if (session.accountId != targetAccountId) {
      return AuthzDecision.denyNotAuthorized;
    }
    return AuthzDecision.allow;
  }
}
