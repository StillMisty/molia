/// 本地数据库（drift）：资料库（播放历史 / 用户列表 / 删除墓碑 / 同步已知版本）
/// + 跨设备增量日志（sync_journal / sync_journal_state）+ 听歌统计
/// （play_events / play_tracks）+ 本地下载 + 播放会话。
///
/// `schemaVersion = 1` 是 fresh 基线（库文件名见 [moliaDatabaseFileName]，
/// 不迁移历史数据）；`2` 新增播放会话两表并保留 v1 数据（见
/// docs/adr/0005-drift-migration.md、docs/adr/0017-playback-session-sql.md）。
///
/// 文件复制 / 目录迁移收在 [appDataDirectory] 旁边的 helper 里（带 `dart:io`），
/// 本文件仍只做库声明与路径选择；`NativeDatabase` 仅测试内存库使用
/// （见 test/support/memory_database.dart）。
library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/models/device_sync.dart';
import 'files/app_data_directory.dart';
import 'molia_database.steps.dart';

part 'molia_database.g.dart';

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
  'WHERE syncId IS NOT NULL',
)
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
  columns: {#playlistId, #sortOrder, #addedAt},
)
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

/// 统计曲目内容：元数据 + 取链参数，**每曲一行**（`UNIQUE (sourceKey, songId)`）。
///
/// 为什么独立成表：`play_events` 是 append-only 的事件流，逐行复制元数据与
/// 载荷（LX 脚本原样透传平台对象时单条 2–8 KB）在保留窗口（20k 行 / 365 天）
/// 下把库顶到数十 MB（实测 18 MB 内置平台载荷 / 97 MB 平台对象）。
/// 语义：元数据是**该曲最近一次播放时的快照**（每曲一份，不逐事件复制），
/// `raw` 按 gzip 存 BLOB（见 `stats_payload_codec.dart`），`updatedAt` 供载荷
/// 预算按「最近播放」保留（`PlayStatisticsRepository.pruneOldEvents`）。
/// 引用的行由 `play_events.trackId` 关联（`ON DELETE RESTRICT`：裁曲目前先删
/// 事件，误删有事件的曲目会直接报错而不是静默丢数据）。
@DataClassName('PlayTrackRow')
class PlayTracks extends Table {
  @override
  String get tableName => 'play_tracks';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get sourceKey => text()();
  TextColumn get songId => text()();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get artist => text().withDefault(const Constant(''))();
  TextColumn get album => text().withDefault(const Constant(''))();
  TextColumn get coverUrl => text().nullable()();
  IntColumn get durationMs => integer().nullable()();

  /// 取链参数：gzip(JSON) 字节；NULL = 无载荷（未提供 / 已被载荷预算清掉）。
  BlobColumn get raw => blob().nullable()();

  /// 最近一次写入的内容时间（事件 `startedAt`）。
  IntColumn get updatedAt => integer()();

  @override
  List<String> get customConstraints => const ['UNIQUE (sourceKey, songId)'];
}

/// 听歌统计事件：一次播放尝试一行（append-only）。
///
/// 事件只存**事件自身**的字段（时间 / 进度 / 结束原因 / 版本三元组）；曲目
/// 元数据与取链参数在 [PlayTracks]（`trackId` 关联，每曲一行）。`endedAt` 为
/// null 表示进行中（进程被杀遗留的行由启动时 `closeStaleEvents()` 收尾）。
/// `syncKey` 为跨设备去重键（创建事件时生成，非空且唯一），
/// `originDeviceId` 记录事件产生设备（同时充当版本三元组的 deviceId）。
/// `endedAt` / `startedAt` 是内容时间；版本是 `versionPhysical +
/// versionCounter + originDeviceId`，跨设备「晚收尾覆盖」按版本判定。
@TableIndex(name: 'idx_play_events_startedAt', columns: {#startedAt})
@TableIndex(name: 'idx_play_events_trackId', columns: {#trackId})
@TableIndex(name: 'idx_play_events_endedAt', columns: {#endedAt})
@TableIndex.sql(
  'CREATE UNIQUE INDEX idx_play_events_syncKey ON play_events (syncKey)',
)
@DataClassName('PlayEventRow')
class PlayEvents extends Table {
  @override
  String get tableName => 'play_events';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get trackId =>
      integer().references(PlayTracks, #id, onDelete: KeyAction.restrict)();
  IntColumn get startedAt => integer()();
  IntColumn get endedAt => integer().nullable()();
  IntColumn get listenedMs => integer().withDefault(const Constant(0))();
  IntColumn get maxPositionMs => integer().withDefault(const Constant(0))();
  TextColumn get endReason => text().nullable()();
  TextColumn get syncKey => text()();
  TextColumn get originDeviceId => text().withDefault(const Constant(''))();
  IntColumn get versionPhysical => integer().withDefault(const Constant(0))();
  IntColumn get versionCounter => integer().withDefault(const Constant(0))();
}

/// 播放会话的整份队列快照（单行 `id = 1`）。
///
/// 为什么与游标分表：整份 JSON 含队列每首曲目的原始 payload，大队列下是
/// MB 级大对象；进度 / 下标每次动作都变，把它和 payload 放同一行会让每次
/// `UPDATE` 都重写整份大对象。这里只在队列 / 模式 / 上下文变化时写。
class PlaybackSessionPayloads extends Table {
  @override
  String get tableName => 'playback_session_payloads';

  IntColumn get id => integer()();
  TextColumn get json => text()();

  /// 内容时间（与 JSON 里的 `savedAt` 同义，供游标新旧比较）。
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 播放会话游标（单行 `id = 1`）：下标 / 进度 / 内容时间。
///
/// 动作（播放 / 暂停 / seek / 切歌 / 曲末 / 退后台）时更新；不存在 1Hz
/// 周期写。`cursorIndex` 不叫 `index`：SQLite 关键字，避免生成 SQL 的歧义。
class PlaybackSessionCursors extends Table {
  @override
  String get tableName => 'playback_session_cursors';

  IntColumn get id => integer()();
  IntColumn get cursorIndex => integer()();
  IntColumn get positionMs => integer()();
  IntColumn get savedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 生产库文件名（drift_flutter 落在应用数据目录，见 [_databaseDirectory]）。
///
/// fresh 基线换了文件名：旧库（`molia_database`）不迁移、不读取，避免把
/// 历史 schema 带进新基线。
const String moliaDatabaseFileName = 'molia_database_v2';

@DriftDatabase(
  tables: [
    PlayHistory,
    Playlists,
    PlaylistTracks,
    SyncTombstones,
    SyncKnown,
    SyncJournal,
    SyncJournalStates,
    PlayTracks,
    PlayEvents,
    Downloads,
    PlaybackSessionPayloads,
    PlaybackSessionCursors,
  ],
)
class MoliaDatabase extends _$MoliaDatabase {
  MoliaDatabase(super.e);

  static MoliaDatabase? _instance;

  /// 单例懒加载：不在 app 启动时强制打开数据库，首个查询才建连接。
  static MoliaDatabase get instance => _instance ??= MoliaDatabase(_open());

  static QueryExecutor _open() {
    return driftDatabase(
      name: moliaDatabaseFileName,
      native: DriftNativeOptions(
        databaseDirectory: _databaseDirectory,
        setup: (db) {
          // WAL：读（资料库 / 统计查询）不再被写事务阻塞，写入吞吐也更稳；
          // 文件级持久设置，重复执行无副作用。
          db.execute('PRAGMA journal_mode = WAL');
          // 本地单文件库：同步提交降为 NORMAL，进程崩溃窗口可接受，
          // 避免每次写都 fsync 整个 WAL。
          db.execute('PRAGMA synchronous = NORMAL');
          // 并发写（同步引擎 / 播放写入 / 统计 touch）等锁的上限。
          db.execute('PRAGMA busy_timeout = 5000');
        },
      ),
    );
  }

  /// 数据库目录：应用数据目录（Windows `%LOCALAPPDATA%\top.stillmisty\molia`、
  /// Linux `~/.local/share/top.stillmisty.molia`）。Windows 首次启动会把旧
  /// Roaming 目录里的库（含 WAL / SHM）复制过来；复制失败回退旧目录并记日志，
  /// 下次启动重试。
  ///
  /// 不用文档目录：那是用户可见区域（Windows 的 `Documents`），还可能被
  /// OneDrive 等同步工具接管——SQLite 文件被同步有损坏风险。
  static Future<Object> _databaseDirectory() async {
    try {
      final target = await appDataDirectory();
      if (hasSeparateLegacyDirectory) {
        final legacy = await legacyAppDataDirectory();
        if (legacy != null) {
          final migrated = await migrateLegacyDatabaseFile(
            targetDirectory: target,
            legacyDirectory: legacy,
            fileName: moliaDatabaseFileName,
          );
          if (!migrated) return legacy;
        }
      }
      return target;
    } on MissingPlatformDirectoryException {
      return await getApplicationDocumentsDirectory();
    }
  }

  /// 当前 schema 版本：`1` 为 fresh 基线，`2` 新增播放会话两表。
  ///
  /// 后续结构变更必须写增量迁移：提版本号 → `dart run drift_dev make-migrations`
  /// 生成 schema 快照 → 用 `stepByStep` 写迁移并保留数据（见 ADR-0005）。
  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: stepByStep(
          from1To2: (m, schema) async {
            await m.createTable(schema.playbackSessionPayloads);
            await m.createTable(schema.playbackSessionCursors);
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
