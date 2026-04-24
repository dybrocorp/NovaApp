import 'package:novaapp/features/chat/domain/models.dart';

abstract class ChatRepository {
  Future<List<ChatContact>> getContacts();
  Future<void> saveContact(ChatContact contact);
  
  Future<List<Message>> getMessages(String contactId);
  Future<void> saveMessage(Message message);
  
  Stream<List<Message>> watchMessages(String contactId);
}
