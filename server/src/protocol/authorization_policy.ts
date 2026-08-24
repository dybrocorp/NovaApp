/**
 * Server-side AUTHORIZATION (async, directory-backed).
 *
 * TypeScript port of
 * `lib/core/socket/protocol/authorization_policy.dart` (PASO 4).
 *
 * Authentication != authorization: an authenticated device is NOT
 * automatically allowed to read any conversation, message any user, or
 * signal any peer. Every operation re-checks authorization against the
 * Directory (Supabase membership tables with RLS in production).
 */
import type { Directory } from '../directory/directory.js';
import type { RegisteredSession } from './session_registry.js';

export enum AuthzDecision {
  allow = 'allow',
  denyNotAuthenticated = 'denyNotAuthenticated',
  denyNotAuthorized = 'denyNotAuthorized',
}

export class AuthorizationPolicy {
  constructor(private readonly directory: Directory) {}

  /** message.send: authenticated session AND conversation membership. */
  async canSendMessage(
    session: RegisteredSession | null,
    conversationId: string,
  ): Promise<AuthzDecision> {
    if (!session) return AuthzDecision.denyNotAuthenticated;
    const member = await this.directory.isConversationMember(conversationId, session.accountId);
    return member ? AuthzDecision.allow : AuthzDecision.denyNotAuthorized;
  }

  /** Reading a conversation's events (sync, delivered/read, fan-out). */
  async canReadConversation(
    session: RegisteredSession | null,
    conversationId: string,
  ): Promise<AuthzDecision> {
    if (!session) return AuthzDecision.denyNotAuthenticated;
    const member = await this.directory.isConversationMember(conversationId, session.accountId);
    return member ? AuthzDecision.allow : AuthzDecision.denyNotAuthorized;
  }

  /**
   * call.* signaling: both peers must have a relationship (contacts),
   * neither blocked. Audio/video media NEVER flows through Socket.IO —
   * this only gates WebRTC signaling relay.
   */
  async canSignalCall(
    session: RegisteredSession | null,
    peerAccountId: string,
  ): Promise<AuthzDecision> {
    if (!session) return AuthzDecision.denyNotAuthenticated;
    const related = await this.directory.hasRelationship(session.accountId, peerAccountId);
    return related ? AuthzDecision.allow : AuthzDecision.denyNotAuthorized;
  }

  /** Presence: the viewer must be in the subject's privacy audience. */
  async canViewPresence(
    session: RegisteredSession | null,
    subjectAccountId: string,
  ): Promise<AuthzDecision> {
    if (!session) return AuthzDecision.denyNotAuthenticated;
    const audience = await this.directory.presenceAudience(subjectAccountId);
    return audience.includes(session.accountId)
      ? AuthzDecision.allow
      : AuthzDecision.denyNotAuthorized;
  }

  /** device.* management: only the same ACCOUNT may manage its devices. */
  canManageDevices(
    session: RegisteredSession | null,
    targetAccountId: string,
  ): AuthzDecision {
    if (!session) return AuthzDecision.denyNotAuthenticated;
    return session.accountId === targetAccountId
      ? AuthzDecision.allow
      : AuthzDecision.denyNotAuthorized;
  }
}
