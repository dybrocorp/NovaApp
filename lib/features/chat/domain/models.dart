
enum MessageType { text, image, voice }

class Message {
  final String senderId;
  final String chatId;
  final String? text;
  final String? mediaUrl;
  final MessageType type;
  final DateTime timestamp;
  final bool isMe;
  final String status; // 'sent', 'delivered', 'read'

  Message({
    required this.senderId,
    required this.chatId,
    this.text,
    this.mediaUrl,
    this.type = MessageType.text,
    required this.timestamp,
    required this.isMe,
    this.status = 'sent',
  });

  Map<String, dynamic> toMap() {
    return {
      'senderId': senderId,
      'chatId': chatId,
      'text': text,
      'mediaUrl': mediaUrl,
      'type': type.name,
      'timestamp': timestamp.toIso8601String(),
      'isMe': isMe ? 1 : 0,
      'status': status,
    };
  }

  factory Message.fromMap(Map<String, dynamic> map) {
    return Message(
      senderId: map['senderId'],
      chatId: map['chatId'] ?? 'default_chat',
      text: map['text'],
      mediaUrl: map['mediaUrl'],
      type: MessageType.values.byName(map['type']),
      timestamp: DateTime.parse(map['timestamp']),
      isMe: map['isMe'] == 1,
      status: map['status'] ?? 'sent',
    );
  }
}

class ChatContact {
  final String id;
  final String name;
  final String? lastMessage;
  final DateTime? lastMessageTime;
  final bool isArchived;
  final String? publicKey;

  ChatContact({
    required this.id,
    required this.name,
    this.lastMessage,
    this.lastMessageTime,
    this.isArchived = false,
    this.publicKey,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'lastMessage': lastMessage,
      'lastMessageTime': lastMessageTime?.toIso8601String(),
      'isArchived': isArchived ? 1 : 0,
      'publicKey': publicKey,
    };
  }

  factory ChatContact.fromMap(Map<String, dynamic> map) {
    return ChatContact(
      id: map['id'],
      name: map['name'],
      lastMessage: map['lastMessage'],
      lastMessageTime: map['lastMessageTime'] != null 
          ? DateTime.parse(map['lastMessageTime']) 
          : null,
      isArchived: map['isArchived'] == 1,
      publicKey: map['publicKey'],
    );
  }
}
