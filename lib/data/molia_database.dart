/// 本地数据库（drift）：最近播放上下文（play_contexts）+ 资料库
/// （播放历史 / 用户列表 / 删除墓碑）+ 听歌统计（play_events）。
///
/// fresh 基线：schemaVersion = 1 直接建出全部表，不迁移 sqflite 时代的历史
/// 数据（设计取舍见 docs/adr/0005-drift-migration.md）。
///
/// 只 import drift / drift_flutter / path_provider：Web 编译安全
/// （`NativeDatabase` 仅测试内存库使用，见 test/support/memory_database.dart）。
library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

part 'molia_database.g.dart';

final _logger = Logger();

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
  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
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
        _logger.w('[MoliaDatabase] 跳过无效的播放上下文导入行: $context');
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
