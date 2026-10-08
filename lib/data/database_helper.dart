import 'dart:io';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:convert';
import 'package:logger/logger.dart';

// 本文件使用的 logger 实例
final logger = Logger();

/// 本地数据库：最近播放上下文（play_contexts）+ 资料库（播放历史 / 用户列表）。
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._privateConstructor();
  static Database? _database;

  static const String _dbName = 'molia_database.db';

  /// v2：仅保留 play_contexts；升级时丢弃旧的 tracks/records/translations 表。
  /// v3：新增 play_history / playlists / playlist_tracks（Wave 9 播放持久化）。
  static const int _dbVersion = 3;

  /// 当前 schema 版本（测试用 in-memory 库按此建表）。
  static int get dbVersion => _dbVersion;

  DatabaseHelper._privateConstructor();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDb();
    return _database!;
  }

  Future<Database> _initDb() async {
    Directory documentsDirectory;
    try {
      documentsDirectory = await getApplicationDocumentsDirectory();
    } on MissingPlatformDirectoryException {
      // Linux 上缺少 xdg-user-dirs 时没有文档目录：退回应用支持目录
      // （~/.local/share/<app>），保证最近播放数据库可用。
      documentsDirectory = await getApplicationSupportDirectory();
    }
    String path = join(documentsDirectory.path, _dbName);
    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      // 显式启用外键约束
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
  }

  // 创建数据库表
  Future<void> _onCreate(Database db, int version) => createSchema(db);

  /// 全量建表（onCreate 与测试的 in-memory 库共用同一份 schema）。
  static Future<void> createSchema(Database db) async {
    await createPlayContextsSchema(db);
    await createLibrarySchema(db);
  }

  /// play_contexts（v1 起的最近播放上下文）。
  static Future<void> createPlayContextsSchema(Database db) async {
    await db.execute('''
      CREATE TABLE play_contexts (
        contextUri TEXT PRIMARY KEY,
        contextType TEXT NOT NULL, 
        contextName TEXT NOT NULL,
        imageUrl TEXT,
        lastPlayedAt INTEGER NOT NULL
      );
    ''');
    // 为按 lastPlayedAt 排序添加索引
    await db.execute(
        'CREATE INDEX idx_play_contexts_lastPlayedAt ON play_contexts (lastPlayedAt);');
  }

  /// v3 资料库表：播放历史（上限 500，重复播放按唯一键更新时间）、
  /// 用户列表与列表曲目（列表内唯一约束保证导入/收藏幂等）。
  static Future<void> createLibrarySchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS play_history (
        sourceKey TEXT NOT NULL,
        songId TEXT NOT NULL,
        title TEXT NOT NULL,
        artist TEXT NOT NULL DEFAULT '',
        album TEXT NOT NULL DEFAULT '',
        coverUrl TEXT,
        durationMs INTEGER,
        raw TEXT NOT NULL DEFAULT '{}',
        playedAt INTEGER NOT NULL,
        UNIQUE (sourceKey, songId)
      );
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_play_history_playedAt ON play_history (playedAt);');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        createdAt INTEGER NOT NULL
      );
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS playlist_tracks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        playlistId INTEGER NOT NULL,
        sourceKey TEXT NOT NULL,
        songId TEXT NOT NULL,
        title TEXT NOT NULL,
        artist TEXT NOT NULL DEFAULT '',
        album TEXT NOT NULL DEFAULT '',
        coverUrl TEXT,
        durationMs INTEGER,
        raw TEXT NOT NULL DEFAULT '{}',
        addedAt INTEGER NOT NULL,
        sortOrder INTEGER NOT NULL DEFAULT 0,
        UNIQUE (playlistId, sourceKey, songId),
        FOREIGN KEY (playlistId) REFERENCES playlists (id) ON DELETE CASCADE
      );
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_playlist_tracks_order ON playlist_tracks (playlistId, sortOrder, addedAt);');
  }

  /// v1 → v2：删除笔记/记录/翻译/曲目表（功能已移除）。
  /// v2 → v3：新增资料库表（保留 play_contexts，不动旧数据）。
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('DROP TABLE IF EXISTS records');
      await db.execute('DROP TABLE IF EXISTS translations');
      await db.execute('DROP TABLE IF EXISTS tracks');
    }
    if (oldVersion < 3) {
      await createLibrarySchema(db);
    }
  }

  /// 插入或更新播放上下文。
  /// 相同 URI 的上下文已存在时更新 lastPlayedAt 时间戳，
  /// 否则插入新上下文。
  Future<void> insertOrUpdatePlayContext({
    required String contextUri,
    required String contextType,
    required String contextName,
    required String? imageUrl,
    required int lastPlayedAt,
  }) async {
    final db = await instance.database;
    final dataToInsert = {
      'contextUri': contextUri,
      'contextType': contextType,
      'contextName': contextName,
      'imageUrl': imageUrl,
      'lastPlayedAt': lastPlayedAt,
    };
    logger.d(
        '[DBHelper] Attempting to insert/update play_context: ${json.encode(dataToInsert)}');
    try {
      await db.insert(
        'play_contexts',
        dataToInsert,
        conflictAlgorithm:
            ConflictAlgorithm.replace, // Replace 在主键已存在时更新
      );
      logger.d(
          '[DBHelper] Successfully inserted/updated play_context for URI: $contextUri');
    } catch (e, s) {
      logger.e('[DBHelper] Error inserting/updating play_context',
          error: e, stackTrace: s);
      rethrow; // 继续抛出，交由 provider 层处理
    }
  }

  /// 获取最近的播放上下文，按 lastPlayedAt 降序排列。
  /// 结果数量由 limit 限制。
  Future<List<Map<String, dynamic>>> getRecentPlayContexts(int limit) async {
    final db = await instance.database;
    logger.d(
        '[DBHelper] Querying play_contexts, orderBy: lastPlayedAt DESC, limit: $limit');
    try {
      final List<Map<String, dynamic>> maps = await db.query(
        'play_contexts',
        orderBy: 'lastPlayedAt DESC',
        limit: limit,
      );
      logger.d(
          '[DBHelper] Query successful, returned ${maps.length} contexts.');
      return maps;
    } catch (e, s) {
      logger.e('[DBHelper] Error querying play_contexts',
          error: e, stackTrace: s);
      rethrow;
    }
  }

  /// 获取全部播放上下文。
  Future<List<Map<String, dynamic>>> getAllPlayContexts() async {
    final db = await instance.database;
    logger.d('[DBHelper] Querying all play_contexts...');
    try {
      final List<Map<String, dynamic>> maps = await db.query('play_contexts');
      logger.d(
          '[DBHelper] getAllPlayContexts successful, returned ${maps.length} contexts.');
      return maps;
    } catch (e, s) {
      logger.e('[DBHelper] Error querying all play_contexts',
          error: e, stackTrace: s);
      rethrow;
    }
  }

  /// 批量插入或替换播放上下文。
  Future<void> batchInsertOrReplacePlayContexts(
      List<Map<String, dynamic>> contexts) async {
    if (contexts.isEmpty) return;
    final db = await instance.database;
    final batch = db.batch();
    logger.d(
        '[DBHelper] Starting batch insert/replace for ${contexts.length} play contexts...');
    int count = 0;
    for (final context in contexts) {
      // 入批前做基础校验
      if (context['contextUri'] != null &&
          context['contextType'] != null &&
          context['contextName'] != null &&
          context['lastPlayedAt'] is int) {
        // 确保 lastPlayedAt 为 int
        batch.insert(
          'play_contexts',
          context, // 假定 map 结构与表列一致
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        count++;
      } else {
        logger.w(
            '[DBHelper] Skipping invalid play context data in batch: ${json.encode(context)}');
      }
    }
    if (count > 0) {
      await batch.commit(noResult: true);
      logger.d(
          '[DBHelper] Batch insert/replace for $count play contexts committed.');
    } else {
      logger.w('[DBHelper] No valid play contexts found to commit in batch.');
    }
  }

  Future<void> close() async {
    final db = await instance.database;
    db.close();
    _database = null; // 重置静态变量
  }
}
