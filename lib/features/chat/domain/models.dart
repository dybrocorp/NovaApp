
enum MessageType { text, image, voice, location, contact, poll }

enum VerificationLevel { level1, level2, level3 }

class PollData {
  final String question;
  final List<String> options;
  final Map<int, int> votes; // index -> count
  final bool isClosed;

  PollData({
    required this.question,
    required this.options,
    this.votes = const {},
    this.isClosed = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'question': question,
      'options': options,
      'votes': votes.map((k, v) => MapEntry(k.toString(), v)),
      'isClosed': isClosed ? 1 : 0,
    };
  }

  factory PollData.fromMap(Map<String, dynamic> map) {
    return PollData(
      question: map['question'],
      options: List<String>.from(map['options']),
      votes: (map['votes'] as Map).map((k, v) => MapEntry(int.parse(k), v as int)),
      isClosed: map['isClosed'] == 1,
    );
  }
}

class Message {
  final String senderId;
  final String chatId;
  final String? text;
  final String? mediaUrl;
  final MessageType type;
  final DateTime timestamp;
  final bool isMe;
  final String status; // 'sent', 'delivered', 'read'
  final PollData? pollData;

  Message({
    required this.senderId,
    required this.chatId,
    this.text,
    this.mediaUrl,
    this.type = MessageType.text,
    required this.timestamp,
    required this.isMe,
    this.status = 'sent',
    this.pollData,
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
      'pollData': pollData?.toMap(),
    };
  }

  factory Message.fromMap(Map<String, dynamic> map) {
    return Message(
      senderId: map['senderId'],
      chatId: map['chatId'] ?? 'default_chat',
      text: map['text'],
      mediaUrl: map['mediaUrl'],
      type: MessageType.values.byName(map['type'] ?? 'text'),
      timestamp: DateTime.parse(map['timestamp']),
      isMe: map['isMe'] == 1,
      status: map['status'] ?? 'sent',
      pollData: map['pollData'] != null ? PollData.fromMap(map['pollData']) : null,
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
  final VerificationLevel verificationLevel;

  ChatContact({
    required this.id,
    required this.name,
    this.lastMessage,
    this.lastMessageTime,
    this.isArchived = false,
    this.publicKey,
    this.verificationLevel = VerificationLevel.level1,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'lastMessage': lastMessage,
      'lastMessageTime': lastMessageTime?.toIso8601String(),
      'isArchived': isArchived ? 1 : 0,
      'publicKey': publicKey,
      'verificationLevel': verificationLevel.name,
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
      verificationLevel: VerificationLevel.values.byName(map['verificationLevel'] ?? 'level1'),
    );
  }
}

enum CallType { incoming, outgoing, missed }

class CallLog {
  final String id;
  final String contactId;
  final String contactName;
  final DateTime timestamp;
  final CallType type;
  final bool isVideo;

  CallLog({
    required this.id,
    required this.contactId,
    required this.contactName,
    required this.timestamp,
    required this.type,
    this.isVideo = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'contactId': contactId,
      'contactName': contactName,
      'timestamp': timestamp.toIso8601String(),
      'type': type.name,
      'isVideo': isVideo ? 1 : 0,
    };
  }

  factory CallLog.fromMap(Map<String, dynamic> map) {
    return CallLog(
      id: map['id'],
      contactId: map['contactId'],
      contactName: map['contactName'],
      timestamp: DateTime.parse(map['timestamp']),
      type: CallType.values.byName(map['type']),
      isVideo: map['isVideo'] == 1,
    );
  }
}
class ChatGroup {
  final String id;
  final String name;
  final List<String> memberIds;
  final String? avatarPath;
  final bool isArchived;

  ChatGroup({
    required this.id,
    required this.name,
    required this.memberIds,
    this.avatarPath,
    this.isArchived = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'memberIds': memberIds,
      'avatarPath': avatarPath,
      'isArchived': isArchived ? 1 : 0,
    };
  }

  factory ChatGroup.fromMap(Map<String, dynamic> map) {
    return ChatGroup(
      id: map['id'],
      name: map['name'],
      memberIds: List<String>.from(map['memberIds']),
      avatarPath: map['avatarPath'],
      isArchived: map['isArchived'] == 1,
    );
  }
}
