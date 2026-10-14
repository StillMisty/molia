/// 本地数据库（drift）：最近播放上下文（play_contexts）+ 资料库
/// （播放历史 / 用户列表 / 删除墓碑）+ 听歌统计（play_events）。
///
/// fresh 基线：schemaVersion = 1 直接建出全部表，不迁移 sqflite 历史库的
/// 数据（设计取舍与后果见 docs/adr/0005-drift-migration.md）；
/// v2 新增 `downloads` 表（本地下载持久副本）。
///
/// 只 import drift / drift_flutter / path_provider：Web 编译安全
/// （`NativeDatabase` 仅测试内存库使用，见 test/support/memory_database.dart）。
library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import 'molia_database.steps.dart';

part 'molia_database.g.dart';

final _logger = Logger('molia.molia_database');

/// play_contexts（v1 起的最近播放上下文）。
@TableIndex(name: 'idx_play_contexts_lastPlayedAt', columns: {#lastPlayedAt})
class PlayContexts extends Table {
  @override
  String get tableName => 'play_contexts';

  // SQLite 的列级/表级 TEXT PRIMARY KEY 都不隐含 NOT NULL，这里保持与旧
  // schema 相同的约束（写入方始终提供非空 URI，但约束不额外收紧）。
  TextColumn get contextUri => text().nullable()();
  TextColumn get contextType => text()();
  TextColumn get contextName => text()();
  TextColumn get imageUrl => text().nullable()();
  IntColumn get lastPlayedAt => integer()();

  @override
  Set<Column> get primaryKey => {contextUri};
}

/// 播放历史（上限 500，重复播放按唯一键更新时间）。
@TableIndex(name: 'idx_play_history_playedAt', columns: {#playedAt})
class PlayHistory extends Table {
  @override
  String get tableName => 'play_history';

  TextColumn get sourceKey => text()();
  TextColumn get songId => text()();
  TextColumn get title => text()();
  TextColumn get artist => text().withDefault(const Constant(''))();
  TextColumn get album => text().withDefault(const Constant(''))();
  TextColumn get coverUrl => text().nullable()();
  IntColumn get durationMs => integer().nullable()();
  TextColumn get raw => text().withDefault(const Constant('{}'))();
  IntColumn get playedAt => integer()();

  @override
  List<String> get customConstraints => const ['UNIQUE (sourceKey, songId)'];
}

/// 用户列表。同步戳 `updatedAt` + `updatedBy` 决定跨设备合并时的逐行新旧；
/// `syncId` 是跨设备稳定的列表标识（自增 id 只在本机有效）。
@TableIndex.sql(
    'CREATE UNIQUE INDEX idx_playlists_syncId ON playlists (syncId) '
    'WHERE syncId IS NOT NULL')
class Playlists extends Table {
  @override
  String get tableName => 'playlists';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  IntColumn get createdAt => integer()();
  TextColumn get syncId => text().nullable()();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();
  TextColumn get updatedBy => text().withDefault(const Constant(''))();
}

/// 列表曲目（列表内唯一约束保证导入/收藏幂等；列表删除级联删曲目）。
@DataClassName('PlaylistTrackRow')
@TableIndex(
    name: 'idx_playlist_tracks_order',
    columns: {#playlistId, #sortOrder, #addedAt})
class PlaylistTracks extends Table {
  @override
  String get tableName => 'playlist_tracks';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get playlistId => integer()();
  TextColumn get sourceKey => text()();
  TextColumn get songId => text()();
  TextColumn get title => text()();
  TextColumn get artist => text().withDefault(const Constant(''))();
  TextColumn get album => text().withDefault(const Constant(''))();
  TextColumn get coverUrl => text().nullable()();
  IntColumn get durationMs => integer().nullable()();
  TextColumn get raw => text().withDefault(const Constant('{}'))();
  IntColumn get addedAt => integer()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();
  TextColumn get updatedBy => text().withDefault(const Constant(''))();

  @override
  List<String> get customConstraints => const [
        'UNIQUE (playlistId, sourceKey, songId)',
        'FOREIGN KEY (playlistId) REFERENCES playlists (id) ON DELETE CASCADE',
      ];
}

/// 删除墓碑：本地删除（列表/曲目/脚本）不保留原行，墓碑承担「删除也取新」
/// 的合并语义；category 取值见 SyncCategory.name。
class SyncTombstones extends Table {
  @override
  String get tableName => 'sync_tombstones';

  TextColumn get category => text()();
  TextColumn get key => text()();
  IntColumn get updatedAt => integer()();
  TextColumn get updatedBy => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {category, key};
}

/// 本地下载（持久副本，不参与缓存 LRU 淘汰）。
///
/// 行内保存曲目自包含快照（元数据 + 原音源 raw 取链参数），供「已下载」
/// 列表还原本地曲目（`sourceKey = 'local'` + 带路径的 payload）与加入歌单；
/// `originSourceKey`/`originSongId` 是**原音源**的曲目键（本地副本删除后
/// 用户仍可回到在线音源播放），唯一约束保证一首原曲只下载一份。
///
/// 歌词/封面路径指向 `downloads/lyrics|covers/` 下的长期文件（Phase 2），
/// 删除下载时一并删除；「清理缓存」永不触碰这些文件。
@DataClassName('DownloadRow')
@TableIndex(name: 'idx_downloads_downloadedAt', columns: {#downloadedAt})
class Downloads extends Table {
  @override
  String get tableName => 'downloads';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get originSourceKey => text()();
  TextColumn get originSongId => text()();
  TextColumn get title => text()();
  TextColumn get artist => text().withDefault(const Constant(''))();
  TextColumn get album => text().withDefault(const Constant(''))();
  TextColumn get coverUrl => text().nullable()();
  IntColumn get durationMs => integer().nullable()();
  TextColumn get raw => text().withDefault(const Constant('{}'))();
  TextColumn get quality => text().withDefault(const Constant(''))();
  // 可空：下载记录可以只含歌词或只含封面（分项下载），音频未下载时为 null。
  TextColumn get filePath => text().nullable()();
  IntColumn get sizeBytes => integer().withDefault(const Constant(0))();
  TextColumn get lyricPath => text().nullable()();
  TextColumn get coverPath => text().nullable()();
  IntColumn get downloadedAt => integer()();

  @override
  List<String> get customConstraints => const [
        'UNIQUE (originSourceKey, originSongId)',
      ];
}

/// 听歌统计事件：一次播放尝试一行（append-only）。
///
/// 元数据为播放时快照、自包含（`raw` 供统计页点播）；`endedAt` 为 null
/// 表示进行中（进程被杀遗留的行由启动时 `closeStaleEvents()` 收尾）。
/// `syncKey` 为跨设备去重键（新事件 UUID；存量行导出时回填哈希），
/// `originDeviceId` 记录事件产生设备。
@TableIndex(name: 'idx_play_events_startedAt', columns: {#startedAt})
@TableIndex(name: 'idx_play_events_track', columns: {#sourceKey, #songId})
@TableIndex.sql(
    'CREATE UNIQUE INDEX idx_play_events_syncKey ON play_events (syncKey) '
    'WHERE syncKey IS NOT NULL')
@DataClassName('PlayEventRow')
class PlayEvents extends Table {
  @override
  String get tableName => 'play_events';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get sourceKey => text()();
  TextColumn get songId => text()();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get artist => text().withDefault(const Constant(''))();
  TextColumn get album => text().withDefault(const Constant(''))();
  TextColumn get coverUrl => text().nullable()();
  IntColumn get durationMs => integer().nullable()();
  TextColumn get raw => text().withDefault(const Constant('{}'))();
  IntColumn get startedAt => integer()();
  IntColumn get endedAt => integer().nullable()();
  IntColumn get listenedMs => integer().withDefault(const Constant(0))();
  IntColumn get maxPositionMs => integer().withDefault(const Constant(0))();
  TextColumn get endReason => text().nullable()();
  TextColumn get syncKey => text().nullable()();
  TextColumn get originDeviceId => text().withDefault(const Constant(''))();
}

/// 生产库文件名（drift_flutter 落在文档目录，回退逻辑见
/// [_databaseDirectory]）。
const String moliaDatabaseFileName = 'molia_database';

@DriftDatabase(tables: [
  PlayContexts,
  PlayHistory,
  Playlists,
  PlaylistTracks,
  SyncTombstones,
  PlayEvents,
  Downloads,
])
class MoliaDatabase extends _$MoliaDatabase {
  MoliaDatabase(super.e);

  static MoliaDatabase? _instance;

  /// 单例懒加载：不在 app 启动时强制打开数据库，首个查询才建连接。
  static MoliaDatabase get instance => _instance ??= MoliaDatabase(_open());

  static QueryExecutor _open() {
    return driftDatabase(
      name: moliaDatabaseFileName,
      native: DriftNativeOptions(databaseDirectory: _databaseDirectory),
    );
  }

  /// 数据库目录：文档目录不可用时回退应用支持目录（Linux 缺少
  /// xdg-user-dirs 时没有文档目录），保证最近播放数据库可用。
  static Future<Object> _databaseDirectory() async {
    try {
      return await getApplicationDocumentsDirectory();
    } on MissingPlatformDirectoryException {
      return await getApplicationSupportDirectory();
    }
  }

  /// fresh 基线：v1 直接建出全部表，不写任何历史数据迁移。
  ///
  /// v2：新增 `downloads` 表（本地下载持久副本）。
  /// v3：`downloads.filePath` 改可空（下载记录可只含歌词 / 封面）。
  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        // 增量迁移走 make-migrations 生成的版本化 schema（steps 文件）：
        // createTable 不含索引声明，索引需单独创建。
        onUpgrade: stepByStep(
          from1To2: (m, schema) async {
            await m.createTable(schema.downloads);
            await m.createIndex(schema.idxDownloadsDownloadedAt);
          },
          from2To3: (m, schema) async {
            // 仅 filePath 由 NOT NULL 改为可空：重建表并原样搬运数据。
            await m.alterTable(TableMigration(schema.downloads));
          },
        ),
        beforeOpen: (details) async {
          // SQLite 外键默认关闭，这里显式开启（列表删除级联依赖它）。
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  @override
  Future<void> close() async {
    if (identical(_instance, this)) _instance = null;
    await super.close();
  }

  /// 插入或更新播放上下文（主键冲突时整体替换）。
  Future<void> insertOrUpdatePlayContext({
    required String contextUri,
    required String contextType,
    required String contextName,
    required String? imageUrl,
    required int lastPlayedAt,
  }) {
    return into(playContexts).insert(
      PlayContextsCompanion.insert(
        contextUri: Value(contextUri),
        contextType: contextType,
        contextName: contextName,
        imageUrl: Value(imageUrl),
        lastPlayedAt: lastPlayedAt,
      ),
      mode: InsertMode.insertOrReplace,
    );
  }

  /// 最近的播放上下文，按 lastPlayedAt 降序。
  Future<List<PlayContext>> getRecentPlayContexts(int limit) {
    return (select(playContexts)
          ..orderBy([(t) => OrderingTerm.desc(t.lastPlayedAt)])
          ..limit(limit))
        .get();
  }

  /// 全部播放上下文（导出用）。
  Future<List<PlayContext>> getAllPlayContexts() => select(playContexts).get();

  /// 批量插入或替换播放上下文；字段缺失的行跳过并记一条警告。
  Future<void> batchInsertOrReplacePlayContexts(
    List<Map<String, dynamic>> contexts,
  ) async {
    if (contexts.isEmpty) return;
    final rows = <PlayContextsCompanion>[];
    for (final context in contexts) {
      if (context['contextUri'] != null &&
          context['contextType'] != null &&
          context['contextName'] != null &&
          context['lastPlayedAt'] is int) {
        rows.add(PlayContextsCompanion.insert(
          contextUri: Value(context['contextUri'] as String),
          contextType: context['contextType'] as String,
          contextName: context['contextName'] as String,
          imageUrl: Value(context['imageUrl'] as String?),
          lastPlayedAt: context['lastPlayedAt'] as int,
        ));
      } else {
        _logger.warning('[MoliaDatabase] 跳过无效的播放上下文导入行: $context');
      }
    }
    if (rows.isEmpty) return;
    await batch((b) => b.insertAll(
          playContexts,
          rows,
          mode: InsertMode.insertOrReplace,
        ));
  }
}
