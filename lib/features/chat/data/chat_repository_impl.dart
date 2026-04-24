import 'dart:async';
import 'package:novaapp/core/services/database_service.dart';
import 'package:novaapp/core/services/encryption_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';
import 'package:novaapp/features/chat/domain/chat_repository.dart';
import 'package:novaapp/features/chat/domain/models.dart';
import 'package:sqflite/sqflite.dart';

class ChatRepositoryImpl implements ChatRepository {
  final DatabaseService _dbService;
  final EncryptionService _encryptionService;
  final SupabaseService _supabaseService;
  StreamController<List<Message>>? _messagesController;

  ChatRepositoryImpl(this._dbService, this._encryptionService, this._supabaseService);

  @override
  Future<List<ChatContact>> getContacts() async {
    final db = await _dbService.database;
    final List<Map<String, dynamic>> maps = await db.query('contacts');
    return maps.map((m) => ChatContact.fromMap(m)).toList();
  }

  @override
  Future<void> saveContact(ChatContact contact) async {
    final db = await _dbService.database;
    await db.insert('contacts', contact.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Stream<List<Message>> watchMessages(String contactId) {
    _messagesController?.close();
    _messagesController = StreamController<List<Message>>.broadcast();

    _loadLocalMessages(contactId);

    // Watch Supabase stream
    _supabaseService.client
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('chatId', contactId)
        .listen((data) async {
          final db = await _dbService.database;
          final contact = await _getContact(contactId);
          
          for (var map in data) {
            String? decryptedText = map['text'];
            
            // Decrypt if it's from peer and we have their public key
            if (map['isMe'] == 0 && contact?.publicKey != null && decryptedText != null) {
              try {
                decryptedText = await _encryptionService.decryptMessage(decryptedText, contact!.publicKey!);
              } catch (e) {
                decryptedText = "[Error de Descifrado]";
              }
            }

            final messageMap = {...map, 'text': decryptedText};
            await db.insert('messages', messageMap, conflictAlgorithm: ConflictAlgorithm.replace);
          }
          _loadLocalMessages(contactId);
        });

    return _messagesController!.stream;
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
    _messagesController?.add(messages);
  }

  @override
  Future<void> saveMessage(Message message) async {
    final db = await _dbService.database;
    final contact = await _getContact(message.chatId);
    
    // 1. Save locally as-is (plaintext)
    await db.insert('messages', message.toMap());
    
    // 2. Prepare for remote (encrypt)
    String? encryptedText = message.text;
    if (contact?.publicKey != null && message.text != null) {
      try {
        encryptedText = await _encryptionService.encryptMessage(message.text!, contact!.publicKey!);
      } catch (e) {
        // Enviar original si falla (aunque Threema fallaría a propósito)
      }
    }

    final remoteMap = {...message.toMap(), 'text': encryptedText};

    try {
      await _supabaseService.client.from('messages').insert(remoteMap);
    } catch (e) {
      // Offline
    }
    
    _loadLocalMessages(message.chatId);
  }
}
