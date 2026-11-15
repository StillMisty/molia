import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/library_browse.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:molia/domain/models/smart_lists.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/local_library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/download/download_records.dart';

import 'support/fakes.dart';
import 'support/memory_database.dart';
import 'support/sync_test_support.dart';

/// 聚合读取次数：本轮优化的验收标准是「历史写入不再重读整库 / 统计」。
class _CountingLibraryRepository extends LibraryRepository {
  _CountingLibraryRepository({required super.databaseProvider})
    : super(stamps: testStampIssuer());

  int browseCalls = 0;

  @override
  Future<({List<PlaylistTrack> favorites, List<BrowsePlaylist> playlists})>
  loadBrowseTracks() {
    browseCalls++;
    return super.loadBrowseTracks();
  }
}

class _CountingStatisticsRepository extends PlayStatisticsRepository {
  _CountingStatisticsRepository({
    required MoliaDatabase Function() databaseProvider,
  }) : super(
         databaseProvider: databaseProvider,
         statisticsSync: testStatisticsSyncStore(databaseProvider),
       );

  int topTracksCalls = 0;
  int playedKeysCalls = 0;

  @override
  Future<List<PlayStatTrackEntry>> topTracks({
    int? since,
    int? until,
    int limit = 10,
    bool byListening = false,
  }) {
    topTracksCalls++;
    return super.topTracks(
      since: since,
      until: until,
      limit: limit,
      byListening: byListening,
    );
  }

  @override
  Future<Set<String>> playedTrackKeys() {
    playedKeysCalls++;
    return super.playedTrackKeys();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // PlaybackProvider 构造期会碰偏好读取（会话清理等），给测试一个空存储。
  SharedPreferences.setMockInitialValues(const {});

  late MoliaDatabase db;
  late _CountingLibraryRepository repository;
  late _CountingStatisticsRepository statistics;
  late DownloadRecords downloads;
  late PlaybackProvider playback;
  late LibraryProvider library;
  late LocalLibraryProvider provider;

  setUp(() async {
    db = openMemoryDatabase();
    repository = _CountingLibraryRepository(databaseProvider: () => db);
    statistics = _CountingStatisticsRepository(databaseProvider: () => db);
    downloads = DownloadRecords(initialized: true, supported: false);
    playback = buildTestPlaybackProvider();
    library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    // 防抖设成一天：测试里手动 refresh()，不受构造时的定时器干扰。
    provider = LocalLibraryProvider(
      repository: repository,
      downloads: downloads,
      library: library,
      statistics: statistics,
      debounce: const Duration(days: 1),
    );
  });

  tearDown(() async {
    provider.dispose();
    library.dispose();
    playback.dispose();
    await statistics.dispose();
    await db.close();
  });

  /// 让构造 / 事件流里的异步任务落地，再手动处理失效标记。
  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await provider.refresh();
  }

  test('首次 refresh 读取浏览索引 + 统计，并发布快照', () async {
    await provider.refresh();
    expect(repository.browseCalls, 1);
    expect(statistics.topTracksCalls, 2, reason: '播放次数 / 收听时长两榜');
    expect(statistics.playedKeysCalls, 1);
    expect(provider.snapshot, isNotNull);
    expect(provider.smartRows.keys, containsAll(SmartListIds.all));
  });

  test('单条播放历史只重建智能列表：不重读整库、不重读统计', () async {
    await library.refreshHistory(force: true);
    await provider.refresh();
    repository.browseCalls = 0;
    statistics.topTracksCalls = 0;
    statistics.playedKeysCalls = 0;

    await repository.addHistoryEntry(
      PlayHistoryEntry(
        sourceKey: 'wy',
        songId: 'h1',
        title: '刚播过',
        playedAt: 1700000000000,
      ),
    );
    await settle();

    expect(repository.browseCalls, 0, reason: '历史不改变专辑 / 歌手索引');
    expect(statistics.topTracksCalls, 0, reason: '统计榜由统计变更单独驱动');
    expect(statistics.playedKeysCalls, 0);
    final recent = provider.smartRows[SmartListIds.recentlyPlayed] ?? const [];
    expect(recent, isNotEmpty, reason: '新增历史行要出现在「最近播放」里');
  });

  test('收藏切换重读浏览索引，但仍不重读统计', () async {
    await provider.refresh();
    repository.browseCalls = 0;
    statistics.topTracksCalls = 0;

    await repository.toggleFavorite(sourceKey: 'wy', songId: 'f1', title: '收藏');
    await settle();

    expect(repository.browseCalls, 1);
    expect(statistics.topTracksCalls, 0);
  });

  test('切换最常播放指标只重建行，不触发数据库读取', () async {
    await provider.refresh();
    repository.browseCalls = 0;
    statistics.topTracksCalls = 0;

    provider.setMostPlayedMetric(SmartListMetric.listeningTime);
    await Future<void>.delayed(Duration.zero);

    expect(repository.browseCalls, 0);
    expect(statistics.topTracksCalls, 0);
  });
}
