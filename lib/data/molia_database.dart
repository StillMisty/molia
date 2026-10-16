/// 本地数据库（drift）：最近播放上下文（play_contexts）+ 资料库
/// （播放历史 / 用户列表 / 删除墓碑 / 同步已知版本）+ 跨设备增量日志
/// （sync_journal / sync_journal_state）+ 听歌统计（play_events）+ 本地下载。
///
/// `schemaVersion = 3`（v1 → v2 新增 `sync_known`，v2 → v3 新增增量日志，
/// 均保留既有数据）；后续结构变更同样必须写增量迁移、保留数据
/// （见 docs/adr/0005-drift-migration.md）。
///
/// 只 import drift / drift_flutter / path_provider：Web 编译安全
/// （`NativeDatabase` 仅测试内存库使用，见 test/support/memory_database.dart）。
library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/models/device_sync.dart';
import 'molia_database.steps.dart';

part 'molia_database.g.dart';

final _logger = Logger('molia.molia_database');

/// play_contexts（v1 起的最近播放上下文）。
@TableIndex(name: 'idx_play_contexts_lastPlayedAt', columns: {#lastPlayedAt})
class PlayContexts extends Table {
  @override
  String get tableName => 'play_contexts';

  // SQLite 的列级/表级 TEXT PRIMARY KEY 都不隐含 NOT NULL，这里用 nullable
  // （写入方始终提供非空 URI，约束不额外收紧）。
  TextColumn get contextUri => text().nullable()();
  TextColumn get contextType => text()();
  TextColumn get contextName => text()();
  TextColumn get imageUrl => text().nullable()();
  IntColumn get lastPlayedAt => integer()();

  @override
  Set<Column> get primaryKey => {contextUri};
}

/// 播放历史（上限 500，重复播放按唯一键更新时间）。
///
/// `playedAt` 是内容时间（何时听的），**不参与**跨设备胜负判定；版本是
/// `versionPhysical + versionCounter + deviceId` 三元组。
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
  IntColumn get versionPhysical => integer().withDefault(const Constant(0))();
  IntColumn get versionCounter => integer().withDefault(const Constant(0))();
  TextColumn get deviceId => text().withDefault(const Constant(''))();

  @override
  List<String> get customConstraints => const ['UNIQUE (sourceKey, songId)'];
}

/// 用户列表。同步版本 `versionPhysical + versionCounter + deviceId` 决定跨设备
/// 合并时的逐行新旧；`syncId` 是跨设备稳定的列表标识（自增 id 只在本机有效）。
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
  IntColumn get versionPhysical => integer().withDefault(const Constant(0))();
  IntColumn get versionCounter => integer().withDefault(const Constant(0))();
  TextColumn get deviceId => text().withDefault(const Constant(''))();
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
  IntColumn get versionPhysical => integer().withDefault(const Constant(0))();
  IntColumn get versionCounter => integer().withDefault(const Constant(0))();
  TextColumn get deviceId => text().withDefault(const Constant(''))();

  @override
  List<String> get customConstraints => const [
        'UNIQUE (playlistId, sourceKey, songId)',
        'FOREIGN KEY (playlistId) REFERENCES playlists (id) ON DELETE CASCADE',
      ];
}

/// 删除墓碑：本地删除（列表/曲目/脚本/历史）不保留原行，墓碑承担「删除也取新」
/// 的合并语义；category 取值见 SyncCategory.name。
///
/// 版本三列决定删除 vs 更新的胜负；`deletedAt` 是**真实删除时间**（内容时间）：
/// 只用于历史「删除 vs 播放」的判定与墓碑保留期，不参与胜负判定。
class SyncTombstones extends Table {
  @override
  String get tableName => 'sync_tombstones';

  TextColumn get category => text()();
  TextColumn get key => text()();
  IntColumn get versionPhysical => integer()();
  IntColumn get versionCounter => integer().withDefault(const Constant(0))();
  TextColumn get deviceId => text().withDefault(const Constant(''))();
  IntColumn get deletedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {category, key};
}

/// 同步已知版本登记：`category + key` → 引擎最后一次交给适配器的胜者版本。
///
/// 引擎合并后只把版本与该登记不同的胜者交给适配器（变更集应用），因此
/// 一轮的 apply 与日志计数 ∝ 本轮变更量，不随库大小增长。适配器内部的新旧
/// 判定保留作兜底（登记缺失的首轮仍正确跳过）。主键形状与
/// `sync_tombstones` 一致：不同类别的同名键互不影响。
class SyncKnown extends Table {
  @override
  String get tableName => 'sync_known';

  TextColumn get category => text()();
  TextColumn get key => text()();
  IntColumn get versionPhysical => integer()();
  IntColumn get versionCounter => integer().withDefault(const Constant(0))();
  TextColumn get deviceId => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {category, key};
}

/// 增量日志：本机变更按 `seq` 单调追加（与数据写入同事务）。
///
/// 传输单元 = 变更：对端按自己的游标只拉 `seq > 游标` 的条目，日志按
/// `min(对端 ack)` 与硬上限（时间 / 体积）裁剪；裁剪位置记在
/// [SyncJournalStates]，落后超出窗口的对端改走 bootstrap 全量快照。
/// `data` 是同步记录的 JSON 载荷（墓碑为 null 或 `{'deletedAt': ...}`）；
/// 列名与 [SyncRecord] 字段一一对应。
@TableIndex(name: 'idx_sync_journal_at', columns: {#at})
class SyncJournal extends Table {
  @override
  String get tableName => 'sync_journal';

  IntColumn get seq => integer()();
  TextColumn get category => text()();
  TextColumn get key => text()();
  IntColumn get versionPhysical => integer()();
  IntColumn get versionCounter => integer().withDefault(const Constant(0))();
  TextColumn get deviceId => text().withDefault(const Constant(''))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  TextColumn get data => text().nullable()();

  /// 追加时间（时间硬上限的判据；与 seq 同序推进）。
  IntColumn get at => integer()();

  @override
  Set<Column> get primaryKey => {seq};
}

/// 增量日志的窗口状态（单行，`id = 0`）。
///
/// - [baseSeq]：已裁剪到的位置（窗口起点 = baseSeq + 1）；与日志裁剪同事务
///   更新，保证「窗口边界」不会与条目集合漂移（跨重启也一致）；
/// - [snapshotSeq]：最近构建的全量快照覆盖到的 journal 位置（-1 = 尚未构建）；
///   裁剪永远不超过它，保证落后 / 新加入的对端总能从全量快照 bootstrap。
class SyncJournalStates extends Table {
  @override
  String get tableName => 'sync_journal_state';

  IntColumn get id => integer()();
  IntColumn get baseSeq => integer().withDefault(const Constant(0))();
  IntColumn get snapshotSeq => integer().withDefault(const Constant(-1))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 本地下载（持久副本，不参与缓存 LRU 淘汰）。
///
/// 行内保存曲目自包含快照（元数据 + 原音源 raw 取链参数），供「本地歌曲」
/// 列表还原本地曲目（`sourceKey = 'local'` + 带路径的 payload）与加入歌单；
/// `originSourceKey`/`originSongId` 是**原音源**的曲目键（本地副本删除后
/// 用户仍可回到在线音源播放），唯一约束保证一首原曲只下载一份。
///
/// 歌词/封面路径指向 `downloads/lyrics|covers/` 下的长期文件，
/// 删除下载时一并删除；「清理缓存」永不触碰这些文件。
///
/// `publicUri` 是 Android 公共 Downloads 副本的 content URI：应用目录里的
/// 文件仍是唯一播放取链目标，公共副本只让用户在文件管理器里可见，删除下载时
/// 经平台通道一并回收。
///
/// `imported` = 本地导入（就地引用用户自己文件）：`originSourceKey = 'local'`、
/// `originSongId` = 文件绝对路径；删除记录只移除行，不删原文件。
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
  // 公共 Downloads 副本的 content URI（Android MediaStore）；未发布 / 其余
  // 平台为 null。播放取链不读它，只在删除下载时回收副本。
  TextColumn get publicUri => text().nullable()();
  // 本地导入（就地引用）：删除只移除记录、不动原文件。
  BoolColumn get imported => boolean().withDefault(const Constant(false))();
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
/// `originDeviceId` 记录事件产生设备（同时充当版本三元组的 deviceId）。
/// `endedAt` / `startedAt` 是内容时间；版本是 `versionPhysical +
/// versionCounter + originDeviceId`，跨设备「晚收尾覆盖」按版本判定。
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
  IntColumn get versionPhysical => integer().withDefault(const Constant(0))();
  IntColumn get versionCounter => integer().withDefault(const Constant(0))();
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
  SyncKnown,
  SyncJournal,
  SyncJournalStates,
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

  /// 当前 schema 版本：`1` 建出基线全部表，`2` 新增 `sync_known`，
  /// `3` 新增增量日志（`sync_journal` + `sync_journal_state`）。
  ///
  /// 结构变更必须写增量迁移：提版本号 → `dart run drift_dev make-migrations`
  /// 生成 schema 快照 → 用 `stepByStep` 写迁移并保留数据（见 ADR-0005）。
  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: stepByStep(
          from1To2: (m, schema) async {
            // v1 → v2：新增同步已知版本登记表；既有表与数据原样保留。
            await m.createTable(schema.syncKnown);
          },
          from2To3: (m, schema) async {
            // v2 → v3：新增增量日志与窗口状态表；既有表与数据原样保留。
            await m.createTable(schema.syncJournal);
            await m.createTable(schema.syncJournalState);
            await m.createIndex(schema.idxSyncJournalAt);
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

  /// 全库最大同步版本（物理分量 + 计数）：`SyncStampIssuer` 首次初始化的
  /// 基线 ≧ 全库最大戳（ADR-0003 v2 §2）。deviceId 不参与「继续发号」判定。
  ///
  /// 扫描五张带版本列的表；一次性启动查询，结果集只有一行。
  Future<({int physical, int counter})> maxSyncVersion() async {
    final row = await customSelect('''
      SELECT p, c FROM (
        SELECT versionPhysical AS p, versionCounter AS c FROM playlists
        UNION ALL
        SELECT versionPhysical, versionCounter FROM playlist_tracks
        UNION ALL
        SELECT versionPhysical, versionCounter FROM play_history
        UNION ALL
        SELECT versionPhysical, versionCounter FROM sync_tombstones
        UNION ALL
        SELECT versionPhysical, versionCounter FROM play_events
      )
      ORDER BY p DESC, c DESC
      LIMIT 1
    ''').getSingleOrNull();
    return (
      physical: (row?.data['p'] as num?)?.toInt() ?? 0,
      counter: (row?.data['c'] as num?)?.toInt() ?? 0,
    );
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

// 行内版本三列（`versionPhysical` / `versionCounter` / `deviceId`）的集中转换：
// 同步适配器与仓库都用这里读版本，避免各处手拼三元组（统计事件用
// `originDeviceId` 兼作设备列——事件产生设备就是版本设备）。

/// 列表头的版本三元组。
extension PlaylistSyncVersionX on Playlist {
  SyncVersion get syncVersion => SyncVersion(
        physical: versionPhysical,
        counter: versionCounter,
        deviceId: deviceId,
      );
}

/// 列表曲目的版本三元组。
extension PlaylistTrackSyncVersionX on PlaylistTrackRow {
  SyncVersion get syncVersion => SyncVersion(
        physical: versionPhysical,
        counter: versionCounter,
        deviceId: deviceId,
      );
}

/// 播放历史的版本三元组（`playedAt` 是内容时间，不在其中）。
extension PlayHistorySyncVersionX on PlayHistoryData {
  SyncVersion get syncVersion => SyncVersion(
        physical: versionPhysical,
        counter: versionCounter,
        deviceId: deviceId,
      );
}

/// 墓碑的版本三元组（`deletedAt` 是内容时间，不在其中）。
extension SyncTombstoneSyncVersionX on SyncTombstone {
  SyncVersion get syncVersion => SyncVersion(
        physical: versionPhysical,
        counter: versionCounter,
        deviceId: deviceId,
      );
}

/// 统计事件的版本三元组（`endedAt` / `startedAt` 是内容时间）。
extension PlayEventSyncVersionX on PlayEventRow {
  SyncVersion get syncVersion => SyncVersion(
        physical: versionPhysical,
        counter: versionCounter,
        deviceId: originDeviceId,
      );
}

/// 同步已知版本登记的版本三元组。
extension SyncKnownSyncVersionX on SyncKnownData {
  SyncVersion get syncVersion => SyncVersion(
        physical: versionPhysical,
        counter: versionCounter,
        deviceId: deviceId,
      );
}
