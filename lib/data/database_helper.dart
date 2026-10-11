import 'dart:io';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:convert';
import 'package:logger/logger.dart';

final logger = Logger();

/// 本地数据库：最近播放上下文（play_contexts）+ 资料库（播放历史 / 用户列表）
/// + 听歌统计（play_events）。
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._privateConstructor();
  static Database? _database;

  static const String _dbName = 'molia_database.db';

  /// v2：仅保留 play_contexts；升级时丢弃旧的 tracks/records/translations 表。
  /// v3：新增 play_history / playlists / playlist_tracks（播放持久化）。
  /// v4：新增 play_events（听歌统计，事件级 append-only）。
  /// v5：新增跨设备同步列（playlists.syncId/updatedAt/updatedBy、
  ///     playlist_tracks.updatedAt/updatedBy、play_events.syncKey/originDeviceId）
  ///     与 sync_tombstones（删除墓碑）。
  static const int _dbVersion = 5;

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
      // SQLite 外键默认关闭，这里显式开启
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
  }

  Future<void> _onCreate(Database db, int version) => createSchema(db);

  /// 全量建表（onCreate 与测试的 in-memory 库共用同一份 schema）。
  static Future<void> createSchema(Database db) async {
    await createPlayContextsSchema(db);
    await createLibrarySchema(db);
    await createPlayStatisticsSchema(db);
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
    await db.execute(
        'CREATE INDEX idx_play_contexts_lastPlayedAt ON play_contexts (lastPlayedAt);');
  }

  /// v3 资料库表：播放历史（上限 500，重复播放按唯一键更新时间）、
  /// 用户列表与列表曲目（列表内唯一约束保证导入/收藏幂等）。
  ///
  /// v5 起列表/曲目带同步戳（`updatedAt` + `updatedBy`）：同步合并按
  /// `(updatedAt, updatedBy)` 逐行取新；`syncId` 是跨设备稳定的列表标识
  /// （自增 id 只在本机有效）。
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
        createdAt INTEGER NOT NULL,
        syncId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        updatedBy TEXT NOT NULL DEFAULT ''
      );
    ''');
    await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_playlists_syncId '
        'ON playlists (syncId) WHERE syncId IS NOT NULL;');
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
        updatedAt INTEGER NOT NULL DEFAULT 0,
        updatedBy TEXT NOT NULL DEFAULT '',
        UNIQUE (playlistId, sourceKey, songId),
        FOREIGN KEY (playlistId) REFERENCES playlists (id) ON DELETE CASCADE
      );
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_playlist_tracks_order ON playlist_tracks (playlistId, sortOrder, addedAt);');

    // 删除墓碑：本地删除（列表/曲目/脚本）不保留原行，墓碑承担「删除也取新」
    // 的合并语义；category 取值见 SyncCategory.name。
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_tombstones (
        category TEXT NOT NULL,
        key TEXT NOT NULL,
        updatedAt INTEGER NOT NULL,
        updatedBy TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (category, key)
      );
    ''');
  }

  /// v4 听歌统计表：一次播放尝试一行（append-only）。
  ///
  /// 元数据为播放时快照、自包含（`raw` 供统计页点播）；`endedAt` 为 null
  /// 表示进行中（进程被杀遗留的行由启动时 `closeStaleEvents()` 收尾）。
  /// v5 起 `syncKey` 为跨设备去重键（新事件 UUID；存量行导出时回填哈希），
  /// `originDeviceId` 记录事件产生设备。
  static Future<void> createPlayStatisticsSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS play_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sourceKey TEXT NOT NULL,
        songId TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        artist TEXT NOT NULL DEFAULT '',
        album TEXT NOT NULL DEFAULT '',
        coverUrl TEXT,
        durationMs INTEGER,
        raw TEXT NOT NULL DEFAULT '{}',
        startedAt INTEGER NOT NULL,
        endedAt INTEGER,
        listenedMs INTEGER NOT NULL DEFAULT 0,
        maxPositionMs INTEGER NOT NULL DEFAULT 0,
        endReason TEXT,
        syncKey TEXT,
        originDeviceId TEXT NOT NULL DEFAULT ''
      );
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_play_events_startedAt ON play_events (startedAt);');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_play_events_track ON play_events (sourceKey, songId);');
    await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_play_events_syncKey '
        'ON play_events (syncKey) WHERE syncKey IS NOT NULL;');
  }

  /// v1 → v2：删除笔记/记录/翻译/曲目表（功能已移除）。
  /// v2 → v3：新增资料库表（保留 play_contexts，不动旧数据）。
  /// v3 → v4：新增听歌统计表（保留全部旧数据）。
  /// v4 → v5：补同步列与删除墓碑表；旧行时间戳用创建/加入时间回填，
  ///         事件去重键留空（首次导出时按内容哈希回填）。
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) =>
      upgradeSchema(db, oldVersion, newVersion);

  /// 版本迁移逻辑（独立静态方法便于迁移测试直接驱动）。
  static Future<void> upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute('DROP TABLE IF EXISTS records');
      await db.execute('DROP TABLE IF EXISTS translations');
      await db.execute('DROP TABLE IF EXISTS tracks');
    }
    if (oldVersion < 3) {
      await createLibrarySchema(db);
    }
    if (oldVersion < 4) {
      await createPlayStatisticsSchema(db);
    }
    if (oldVersion < 5) {
      await _upgradeToV5(db);
    }
  }

  /// v5：同步列 + 墓碑表。SQLite 的 ADD COLUMN 需要常量默认值，
  /// 旧行时间戳用已有列回填。
  static Future<void> _upgradeToV5(Database db) async {
    Future<void> addColumn(String table, String column, String definition) async {
      final columns = await db.rawQuery('PRAGMA table_info($table)');
      final exists = columns.any((row) => row['name'] == column);
      if (!exists) {
        await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
      }
    }

    await addColumn('playlists', 'syncId', 'TEXT');
    await addColumn('playlists', 'updatedAt', 'INTEGER NOT NULL DEFAULT 0');
    await addColumn('playlists', 'updatedBy', "TEXT NOT NULL DEFAULT ''");
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_playlists_syncId '
        'ON playlists (syncId) WHERE syncId IS NOT NULL;');
    await db.execute(
        'UPDATE playlists SET updatedAt = createdAt WHERE updatedAt = 0');

    await addColumn('playlist_tracks', 'updatedAt', 'INTEGER NOT NULL DEFAULT 0');
    await addColumn('playlist_tracks', 'updatedBy', "TEXT NOT NULL DEFAULT ''");
    await db.execute(
        'UPDATE playlist_tracks SET updatedAt = addedAt WHERE updatedAt = 0');

    await addColumn('play_events', 'syncKey', 'TEXT');
    await addColumn('play_events', 'originDeviceId', "TEXT NOT NULL DEFAULT ''");
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_play_events_syncKey '
        'ON play_events (syncKey) WHERE syncKey IS NOT NULL;');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_tombstones (
        category TEXT NOT NULL,
        key TEXT NOT NULL,
        updatedAt INTEGER NOT NULL,
        updatedBy TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (category, key)
      );
    ''');
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
    _database = null;
  }
}
