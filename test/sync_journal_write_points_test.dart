import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/data/sync/adapters/prefs_sync_adapter.dart';
import 'package:molia/data/sync/statistics_sync_store.dart';
import 'package:molia/data/sync/sync_journal.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:molia/domain/ports/statistics_sync_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_database.dart';
import 'support/sync_test_support.dart';

/// 本地写入点 → 增量日志：资料库 / 统计在数据写入的同一事务里追加，
/// 设置 / 脚本 / 会话在各自的变化检测点追加；应用远端记录不追加。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MoliaDatabase db;
  late SyncJournalRepository journal;
  late LibraryRepository library;
  late PlayStatisticsRepository statistics;
  late SqliteStatisticsSyncStore statisticsSync;

  setUp(() {
    db = openMemoryDatabase();
    journal = SyncJournalRepository(
      databaseProvider: () => db,
      clock: () => 5000,
    );
    final stamps = testStampIssuer(clock: () => 1000, deviceId: 'devA');
    library = LibraryRepository(
      databaseProvider: () => db,
      clock: () => 1000,
      stamps: stamps,
      journal: journal,
    );
    statisticsSync = SqliteStatisticsSyncStore(
      databaseProvider: () => db,
      stamps: stamps,
      journal: journal,
    );
    statistics = PlayStatisticsRepository(
      databaseProvider: () => db,
      clock: () => 1000,
      statisticsSync: statisticsSync,
    );
  });

  tearDown(() => db.close());

  test('播放历史：写入 / 删除各产生 1 条日志，载荷与同步导出一致', () async {
    await library.addHistoryEntry(const PlayHistoryEntry(
      sourceKey: 'kuwo',
      songId: 'song-1',
      title: '测试歌曲',
      artist: '歌手',
      album: '专辑',
      playedAt: 900,
      raw: {'rid': 42},
    ));

    var window = await journal.window();
    expect(window, hasLength(1));
    final entry = window.single;
    expect(entry.category, SyncCategory.history);
    expect(entry.record.key, SyncRecordKeys.history('kuwo', 'song-1'));
    expect(entry.record.deleted, isFalse);

    // 日志载荷 = 适配器导出的同版本记录（同一版本在日志与快照里必须一致）。
    final exported = (await library.syncExportHistory()).single;
    expect(entry.record.data, exported.toJson());
    expect(entry.record.version, exported.version);

    await library.deleteHistoryEntry('kuwo', 'song-1');
    window = await journal.window(since: 1);
    expect(window, hasLength(1));
    expect(window.single.record.deleted, isTrue);
    expect(window.single.record.version, isNot(entry.record.version));

    // 上限淘汰不写日志（不是用户删除）。
    expect((await library.syncExportTombstones(['history'])), hasLength(1));
  });

  test('列表 / 曲目：新建、重命名、加入、排序、移除都进日志', () async {
    final id = await library.createPlaylist('我的列表');
    final playlists = await library.syncExportPlaylists();
    final syncId = playlists.single.syncId;
    expect(syncId, isNotEmpty);

    await library.addTrackToPlaylist(
      id,
      const PlaylistTrack(
        playlistId: 0,
        sourceKey: 'kuwo',
        songId: 'song-1',
        title: '歌曲',
        artist: '歌手',
        album: '专辑',
        raw: {},
        addedAt: 10,
        sortOrder: 0,
      ),
    );
    await library.addTrackToPlaylist(
      id,
      const PlaylistTrack(
        playlistId: 0,
        sourceKey: 'kuwo',
        songId: 'song-2',
        title: '歌曲二',
        artist: '歌手',
        album: '专辑',
        raw: {},
        addedAt: 11,
        sortOrder: 0,
      ),
    );
    await library.renamePlaylist(id, '改名');
    // 倒序：两行的 sortOrder 都变化 → 2 条日志。
    await library.reorderPlaylistTracks(id, const [
      (sourceKey: 'kuwo', songId: 'song-2'),
      (sourceKey: 'kuwo', songId: 'song-1'),
    ]);
    await library.removeTrackFromPlaylist(id, 'kuwo', 'song-1');

    final window = await journal.window();
    expect(window.map((entry) => entry.category).toSet(), {
      SyncCategory.playlists,
      SyncCategory.playlistTracks,
    });
    // 列表头：新建 + 重命名 = 2 条。
    expect(
      window.where((entry) => entry.category == SyncCategory.playlists),
      hasLength(2),
    );
    // 曲目：加入 ×2 + 排序 ×2 + 移除 = 5 条，最后一条是墓碑。
    final trackEntries = window
        .where((entry) => entry.category == SyncCategory.playlistTracks)
        .toList();
    expect(trackEntries, hasLength(5));
    expect(trackEntries.first.record.key,
        SyncRecordKeys.playlistTrack(syncId, 'kuwo', 'song-1'));
    expect(trackEntries.last.record.deleted, isTrue);
  });

  test('重命名老列表（缺 syncId）：补 syncId 与重命名两条日志版本递增', () async {
    // 造一条没有 syncId 的存量列表。
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(
          name: '老列表',
          createdAt: 1,
        ));
    final id = (await db.select(db.playlists).getSingle()).id;

    await library.renamePlaylist(id, '新名字');

    final window = await journal.window();
    final playlistEntries = window
        .where((entry) => entry.category == SyncCategory.playlists)
        .toList();
    // 补 syncId（旧名） + 重命名（新名）：同键两条，版本必须递增。
    expect(playlistEntries, hasLength(2));
    expect(
      playlistEntries.first.record.version.isNewerThan(
        playlistEntries.last.record.version,
      ),
      isFalse,
      reason: '后写的重命名日志版本必须更大（否则对端 LWW 保留旧名）',
    );
    expect(playlistEntries.last.record.data?['name'], '新名字');
    // 导出的当前视图与最后一条日志一致。
    final exported = (await library.syncExportPlaylists()).single;
    expect(exported.name, '新名字');
    expect(exported.version, playlistEntries.last.record.version);
  });

  test('统计：收尾事件产生 1 条日志；开始播放与进度落盘不产生', () async {
    final id = await statistics.startEvent(
      sourceKey: 'kuwo',
      songId: 'song-1',
      title: '歌曲',
      startedAt: 100,
    );
    await statistics.touchEvent(id, listenedMs: 5000, maxPositionMs: 6000);
    expect(await journal.headSeq(), 0);

    await statistics.finishEvent(
      id,
      reason: PlayEventEndReason.completed,
      listenedMs: 20000,
      maxPositionMs: 20000,
      endedAt: 900,
    );

    final window = await journal.window();
    expect(window, hasLength(1));
    expect(window.single.category, SyncCategory.statistics);
    expect(window.single.record.deleted, isFalse);
    final exported = (await statisticsSync.syncExportEvents()).single;
    expect(window.single.record.key, exported.syncKey);
    expect(window.single.record.data, exported.toData());
  });

  test('统计：进程被杀遗留事件收尾同样进日志', () async {
    final id = await statistics.startEvent(
      sourceKey: 'kuwo',
      songId: 'song-2',
      title: '歌曲',
      startedAt: 100,
    );
    await statistics.touchEvent(id, listenedMs: 3000, maxPositionMs: 3000);
    expect(await journal.headSeq(), 0);

    expect(await statistics.closeStaleEvents(), 1);
    final window = await journal.window();
    expect(window, hasLength(1));
    expect(window.single.category, SyncCategory.statistics);
  });

  test('设置：登记哈希变化才进日志，首次登记不算变更', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySyncSecretStore();
    final state = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => 1000,
    );
    await state.init();
    final settings = SettingsRegistry(
      keys: const [kThemeMode],
      preferences: prefs,
      secrets: secrets,
    );
    final adapter = PrefsSyncAdapter(
      state: state,
      settings: settings,
      journal: journal,
    );

    // 首次登记：不追加（初始视图由全量快照覆盖）。
    await adapter.collect();
    expect(await journal.headSeq(), 0);

    // 本地修改（用户切换主题）→ 登记哈希变化 → 1 条日志。
    await prefs.setString(kThemeMode.name, 'dark');
    final collected = await adapter.collect();
    final window = await journal.window();
    expect(window, hasLength(1));
    expect(window.single.category, SyncCategory.settings);
    expect(window.single.record.key, kThemeMode.name);
    expect(
      window.single.record.version,
      collected[SyncCategory.settings]!.single.version,
    );
    expect(window.single.record.data, {'v': 'dark'});
  });

  test('应用远端记录不追加日志（变更由来源设备广播）', () async {
    final version = SyncVersion(physical: 9000, deviceId: 'devB');
    await library.syncApplyHistory(entries: [
      PlayHistorySyncRecord(
        sourceKey: 'kuwo',
        songId: 'song-9',
        title: '远端歌曲',
        artist: '',
        album: '',
        coverUrl: null,
        durationMs: null,
        raw: '{}',
        playedAt: 900,
        version: version,
      ),
    ]);
    await library.syncApplyLibrary(tombstones: [
      SyncTombstoneRecord(
        category: SyncCategory.history.name,
        key: SyncRecordKeys.history('kuwo', 'song-8'),
        version: version,
        deletedAt: 900,
      ),
    ]);
    await statisticsSync.syncApplyEvents([
      const StatisticsSyncEvent(
        syncKey: 'remote-event',
        version: SyncVersion(physical: 9000, deviceId: 'devB'),
        sourceKey: 'kuwo',
        songId: 'song-7',
        title: '远端',
        startedAt: 1,
        endedAt: 2,
      ),
    ]);

    expect(await journal.headSeq(), 0);
  });
}
