import 'dart:async';
import 'package:novaapp/core/constants.dart';
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
import 'package:flutter_secure_storage/flutter_secure_storage.dart' as secure;

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
    final maps = await db.query(AppConstants.tableContacts);
    return maps.map((m) => ChatContact.fromMap(m)).toList();
  }

  @override
  Future<void> saveContact(ChatContact contact) async {
    final db = await _dbService.database;
    await db.insert(
      AppConstants.tableContacts,
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
        if (myNovaId == null || myNovaId.isEmpty || _isLocalOnlyChat(contactId)) return;

        final remoteChatId = _remoteChatId(myNovaId, contactId);
        client
            .from(AppConstants.tableMessages)
            .stream(primaryKey: [AppConstants.colId])
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
                contact!.publicKey!.isNotEmpty &&
                decryptedText != null &&
                !_isLocalOnlyChat(contactId)) {
              try {
                decryptedText = await _encryptionService.decryptFromSender(
                  decryptedText,
                  contact.publicKey!,
                );
              } catch (e) {
                LoggerService.warning('Decryption failed for message', tag: 'Chat');
                decryptedText = '[Error de Descifrado]';
              }
            }

            final messageMap = {
              'senderId': senderId,
              'chatId': contactId,
              'text': decryptedText,
              'mediaUrl': map['media_url'],
              'type': map['type'] ?? AppConstants.msgTypeText,
              'timestamp': map['timestamp'],
              'isMe': isMine ? 1 : 0,
              'status': map['status'] ?? AppConstants.statusSent,
            };

            final existing = await db.query(
              AppConstants.tableMessages,
              where: 'chatId = ? AND timestamp = ?',
              whereArgs: [contactId, messageMap['timestamp']],
            );

            if (existing.isEmpty) {
              await db.insert(AppConstants.tableMessages, messageMap);
              if (!isMine && contact != null) {
                await _notificationService.showLocalNotification(
                  title: contact.name,
                  body: decryptedText ?? 'Nuevo mensaje',
                  payload: contact.id,
                );
              }
            } else {
              await db.update(
                AppConstants.tableMessages,
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
    final maps = await db.query(AppConstants.tableContacts, where: 'id = ?', whereArgs: [id]);
    if (maps.isNotEmpty) return ChatContact.fromMap(maps.first);
    return null;
  }

  Future<void> _loadLocalMessages(String contactId) async {
    final db = await _dbService.database;
    final maps = await db.query(
      AppConstants.tableMessages,
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

    if (contact != null && myNovaId != null) {
      final isBlocked = await _moderationService.isUserBlocked(
        blockerId: myNovaId,
        blockedId: contact.id,
      );
      if (isBlocked) {
        throw Exception('Cannot send message to blocked user');
      }
    }

    String realSenderId = message.senderId;
    if (realSenderId == 'me') {
      realSenderId = myNovaId ?? realSenderId;
      if (realSenderId == 'me') {
        try {
          final storedId = await const secure.FlutterSecureStorage().read(key: AppConstants.keyNovaId);
          if (storedId != null) realSenderId = storedId;
        } catch (_) {}
      }
    }

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
    await db.insert(AppConstants.tableMessages, localMessage.toMap());

    String? encryptedText = message.text;
    final shouldEncrypt = contact?.publicKey != null &&
        contact!.publicKey!.isNotEmpty &&
        message.text != null &&
        !_isLocalOnlyChat(message.chatId);

    if (shouldEncrypt) {
      try {
        encryptedText = await _encryptionService.encryptForRecipient(
          message.text!,
          contact!.publicKey!,
        );
      } catch (e) {
        LoggerService.error('CRITICAL: Encryption failed', error: e, tag: 'Chat');
        throw StateError('Cannot send: encryption failed');
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
      LoggerService.error('Error sending to Supabase', error: e, tag: 'Chat');
    }

    _loadLocalMessages(message.chatId);
  }

  bool _isLocalOnlyChat(String contactId) {
    return contactId == AppConstants.supportContactId || contactId == AppConstants.privateNotesId;
  }

  String _remoteChatId(String userA, String userB) {
    final ids = [userA, userB]..sort();
    return '${ids[0]}__${ids[1]}';
  }
}
