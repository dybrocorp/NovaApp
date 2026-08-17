import 'dart:async';
import 'package:novaapp/core/services/database_service.dart';
import 'package:novaapp/core/services/encryption_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';
import 'package:novaapp/core/services/notification_service.dart';
import 'package:novaapp/core/services/moderation_service.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/features/auth/data/identity_repository.dart';
import 'package:novaapp/features/chat/domain/chat_repository.dart';
import 'package:novaapp/features/chat/domain/models.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart' as flutter_secure_storage;

class ChatRepositoryImpl implements ChatRepository {
  final DatabaseService _dbService;
  final EncryptionService _encryptionService;
  final SupabaseService _supabaseService;
  final NotificationService _notificationService;
  final IdentityRepository _identityRepository;
  final ModerationService _moderationService;
  final Map<String, StreamController<List<Message>>> _messagesControllers = {};

  ChatRepositoryImpl(
    this._dbService,
    this._encryptionService,
    this._supabaseService,
    this._notificationService,
    this._identityRepository,
    this._moderationService,
  );

  @override
  Future<List<ChatContact>> getContacts() async {
    final db = await _dbService.database;
    final List<Map<String, dynamic>> maps = await db.query('contacts');
    return maps.map((m) => ChatContact.fromMap(m)).toList();
  }

  @override
  Future<void> saveContact(ChatContact contact) async {
    final db = await _dbService.database;
    await db.insert(
      'contacts',
      contact.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Stream<List<Message>> watchMessages(String contactId) {
    _messagesControllers[contactId]?.close();
    final controller = StreamController<List<Message>>.broadcast();
    _messagesControllers[contactId] = controller;

    _loadLocalMessages(contactId);

    final client = _supabaseService.client;
    if (client != null) {
      _identityRepository.getId().then((myNovaId) {
        if (myNovaId == null || myNovaId.isEmpty || _isLocalOnlyChat(contactId)) {
          return;
        }

        final remoteChatId = _remoteChatId(myNovaId, contactId);
        client
            .from('messages')
            .stream(primaryKey: ['id'])
            .eq('chat_id', remoteChatId)
            .listen((data) async {
          final db = await _dbService.database;
          final contact = await _getContact(contactId);

          for (var map in data) {
            String? decryptedText = map['text'];
            final senderId = map['sender_id'] as String? ?? '';
            final isMine = senderId == myNovaId;

            if (!isMine &&
                contact?.publicKey != null &&
                contact?.publicKey!.isNotEmpty == true &&
                decryptedText != null &&
                contact?.id != '+123456789' &&
                contact?.id != 'me_notes') {
              try {
                decryptedText = await _encryptionService.decryptMessageFromSender(
                  decryptedText,
                  contact!.publicKey!,
                );
              } catch (e) {
                decryptedText = "[Error de Descifrado]";
              }
            }

            final messageMap = {
              'senderId': senderId,
              'chatId': contactId,
              'text': decryptedText,
              'mediaUrl': map['media_url'],
              'type': map['type'] ?? 'text',
              'timestamp': map['timestamp'],
              'isMe': isMine ? 1 : 0,
              'status': map['status'] ?? 'sent',
            };

            final existing = await db.query(
              'messages',
              where: 'chatId = ? AND timestamp = ?',
              whereArgs: [contactId, messageMap['timestamp']],
            );

            if (existing.isEmpty) {
              await db.insert('messages', messageMap);

              if (!isMine && contact != null) {
                await _notificationService.showLocalNotification(
                  title: contact.name,
                  body: decryptedText ?? 'Nuevo mensaje',
                  payload: contact.id,
                );
              }
            } else {
              await db.update(
                'messages',
                {'status': messageMap['status']},
                where: 'chatId = ? AND timestamp = ?',
                whereArgs: [contactId, messageMap['timestamp']],
              );
            }
          }
          _loadLocalMessages(contactId);
        });
      });
    }

    return controller.stream;
  }

  Future<ChatContact?> _getContact(String id) async {
    final db = await _dbService.database;
    final List<Map<String, dynamic>> maps = await db.query('contacts', where: 'id = ?', whereArgs: [id]);
    if (maps.isNotEmpty) return ChatContact.fromMap(maps.first);
    return null;
  }

  Future<void> _loadLocalMessages(String contactId) async {
    final db = await _dbService.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      where: 'chatId = ?',
      whereArgs: [contactId],
      orderBy: 'timestamp DESC',
    );
    final messages = maps.map((m) => Message.fromMap(m)).toList();
    _messagesControllers[contactId]?.add(messages);
  }

  @override
  Future<void> saveMessage(Message message) async {
    final db = await _dbService.database;
    final contact = await _getContact(message.chatId);
    final myNovaId = await _identityRepository.getId();

    // Check if recipient is blocked by sender
    if (contact != null && myNovaId != null) {
      final isBlocked = await _moderationService.isUserBlocked(
        blockerId: myNovaId,
        blockedId: contact.id,
      );
      if (isBlocked) {
        throw Exception('Cannot send message to blocked user');
      }
    }

    // Get real sender ID from storage instead of 'me'
    String realSenderId = message.senderId;
    if (realSenderId == 'me') {
      realSenderId = myNovaId ?? realSenderId;
      if (realSenderId == 'me') {
        try {
          final storage = const flutter_secure_storage.FlutterSecureStorage();
          final storedId = await storage.read(key: 'nova_id');
          if (storedId != null) {
            realSenderId = storedId;
          }
        } catch (_) {}
      }
    }

    // 1. Save locally as plaintext, using the real sender id to avoid remote duplicates.
    final localMessage = Message(
      senderId: realSenderId,
      chatId: message.chatId,
      text: message.text,
      mediaUrl: message.mediaUrl,
      type: message.type,
      timestamp: message.timestamp,
      isMe: message.isMe,
      status: message.status,
      pollData: message.pollData,
    );
    await db.insert('messages', localMessage.toMap());

    // 2. Prepare for remote (encrypt)
    String? encryptedText = message.text;
    // Only encrypt if contact has a public key (for real users)
    // Special contacts like "Soporte NovaApp" and "Notas privadas" don't have encryption
    if (contact?.publicKey != null &&
        contact?.publicKey!.isNotEmpty == true &&
        message.text != null &&
        contact?.id != '+123456789' &&
        contact?.id != 'me_notes') {
      try {
        encryptedText = await _encryptionService.encryptMessageForRecipient(
          message.text!,
          contact!.publicKey!,
        );
      } catch (e) {
        LoggerService.warning('Encryption failed, sending plaintext', error: e, tag: 'Chat');
      }
    }

    if (myNovaId == null || myNovaId.isEmpty || _isLocalOnlyChat(message.chatId)) {
      _loadLocalMessages(message.chatId);
      return;
    }

    final remoteMap = {
      'chat_id': _remoteChatId(myNovaId, message.chatId),
      'sender_id': realSenderId,
      'text': encryptedText,
      'media_url': message.mediaUrl,
      'type': message.type.name,
      'timestamp': message.timestamp.toIso8601String(),
      'is_me': message.isMe ? 1 : 0,
      'status': message.status,
    };

    try {
      await _supabaseService.sendMessage(remoteMap);
    } catch (e) {
      LoggerService.error('Error sending message to Supabase', error: e, tag: 'Chat');
    }

    _loadLocalMessages(message.chatId);
  }

  bool _isLocalOnlyChat(String contactId) {
    return contactId == '+123456789' || contactId == 'me_notes';
  }

  String _remoteChatId(String userA, String userB) {
    final ids = [userA, userB]..sort();
    return '${ids[0]}__${ids[1]}';
  }
}
