/// Centralized constants for NovaApp — no magic strings allowed.

class AppConstants {
  AppConstants._();

  // Nova ID
  static const String novaIdPrefix = 'NOVA-';
  static const int novaIdLength = 8;

  // Supabase table names
  static const String tableProfiles = 'profiles';
  static const String tableUsers = 'users';
  static const String tableMessages = 'messages';
  static const String tableContacts = 'contacts';
  static const String tableCallHistory = 'call_history';
  static const String tableReports = 'reports';
  static const String tableBlockedUsers = 'blocked_users';
  static const String tableSignedPreKeys = 'signed_pre_keys';
  static const String tableOneTimePreKeys = 'one_time_pre_keys';
  static const String tableCryptoSessions = 'crypto_sessions';

  // Column names
  static const String colId = 'id';
  static const String colNovaId = 'nova_id';
  static const String colName = 'name';
  static const String colDisplayName = 'display_name';
  static const String colPublicKey = 'public_key';
  static const String colAvatarUrl = 'avatar_url';
  static const String colFcmToken = 'fcm_token';
  static const String colCreatedAt = 'created_at';
  static const String colUpdatedAt = 'updated_at';

  // Special contact IDs (local-only chats)
  static const String supportContactId = '+123456789';
  static const String privateNotesId = 'me_notes';

  // Secure storage keys
  static const String keyPrivateKey = 'nova_private_key';
  static const String keyPublicKey = 'nova_public_key';
  static const String keyNovaId = 'nova_id';
  static const String keyUserName = 'nova_username';
  static const String keyAvatar = 'nova_avatar';
  static const String keyAccountId = 'nova_account_id';
  static const String keyDeviceId = 'nova_device_id';
  static const String keyIdentityKeyPair = 'nova_identity_keypair';
  static const String keySignedPreKeyPair = 'nova_spk_pair';
  static const String keySignedPreKeyId = 'nova_spk_id';
  static const String keyOneTimePreKeyPairs = 'nova_opk_pairs';

  // Key rotation intervals
  static const Duration spkRotationInterval = Duration(days: 7);
  static const int opkBatchSize = 10;

  // Message statuses
  static const String statusSending = 'sending';
  static const String statusSent = 'sent';
  static const String statusDelivered = 'delivered';
  static const String statusRead = 'read';
  static const String statusFailed = 'failed';

  // Message types
  static const String msgTypeText = 'text';
  static const String msgTypeImage = 'image';
  static const String msgTypeVoice = 'voice';
  static const String msgTypeLocation = 'location';
  static const String msgTypeContact = 'contact';
  static const String msgTypePoll = 'poll';
  static const String msgTypeFile = 'file';
  static const String msgTypeVideo = 'video';

  // Privacy levels
  static const String privacyAnyone = 'anyone';
  static const String privacyQrOnly = 'qr_only';
}
