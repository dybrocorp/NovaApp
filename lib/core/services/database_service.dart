import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseService {
  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'nova_app.db');

    return await openDatabase(
      path,
      version: 4,
      onCreate: _onCreate,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try {
            await db.execute('ALTER TABLE contacts ADD COLUMN isArchived INTEGER DEFAULT 0');
          } catch (e) {
            // Column might already exist
          }
          await _seedData(db);
        }
        if (oldVersion < 3) {
          try {
            await db.execute('ALTER TABLE messages ADD COLUMN chatId TEXT');
            await db.execute('ALTER TABLE messages ADD COLUMN status TEXT DEFAULT "sent"');
          } catch (e) {
            // Columns might already exist
          }
        }
        if (oldVersion < 4) {
          try {
            await db.execute('ALTER TABLE contacts ADD COLUMN publicKey TEXT');
          } catch (e) {
            // Column might already exist
          }
        }
      },
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // Contacts Table
    await db.execute('''
      CREATE TABLE contacts (
        id TEXT PRIMARY KEY,
        name TEXT,
        lastMessage TEXT,
        lastMessageTime TEXT,
        isArchived INTEGER DEFAULT 0
      )
    ''');

    // Messages Table
    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        senderId TEXT,
        chatId TEXT,
        text TEXT,
        mediaUrl TEXT,
        type TEXT,
        timestamp TEXT,
        isMe INTEGER,
        status TEXT DEFAULT 'sent'
      )
    ''');

    await _seedData(db);
  }

  Future<void> _seedData(Database db) async {
    // Default Contacts
    await db.insert('contacts', {
      'id': '+123456789',
      'name': 'Soporte NovaApp',
      'lastMessage': '¡Hola! ¿En qué puedo ayudarte?',
      'lastMessageTime': DateTime.now().toIso8601String(),
      'isArchived': 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    await db.insert('contacts', {
      'id': 'me_notes',
      'name': 'Notas privadas',
      'lastMessage': 'Cualquier cosa que envíes aquí...',
      'lastMessageTime': DateTime.now().toIso8601String(),
      'isArchived': 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
