import 'dart:async';
import 'package:novaapp/core/services/database_service.dart';
import 'package:novaapp/features/chat/domain/chat_repository.dart';
import 'package:novaapp/features/chat/domain/models.dart';
import 'package:sqflite/sqflite.dart';

class ChatRepositoryImpl implements ChatRepository {
  final DatabaseService _dbService;
  final _messageController = StreamController<List<Message>>.broadcast();

  ChatRepositoryImpl(this._dbService);

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
  Future<List<Message>> getMessages(String contactId) async {
    final db = await _dbService.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      where: 'chatId = ?',
      whereArgs: [contactId],
      orderBy: 'timestamp DESC',
    );
    return maps.map((m) => Message.fromMap(m)).toList();
  }

  @override
  Future<void> saveMessage(Message message) async {
    final db = await _dbService.database;
    await db.insert('messages', message.toMap());
    
    // Notify listeners (simple implementation)
    final messages = await getMessages(message.senderId);
    _messageController.add(messages);
  }

  @override
  Stream<List<Message>> watchMessages(String contactId) {
    // In a real app, we'd use a more reactive approach with Hive or a custom notifier
    // For now, we'll return the controller's stream
    return _messageController.stream;
  }
}
