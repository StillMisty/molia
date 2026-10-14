import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/downloads/downloads_repository.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/sleep_timer.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage_stub.dart';
import 'package:molia/services/download/download_service.dart';
import 'package:molia/services/track_cache_service.dart';
import 'package:molia/widgets/track_info_view.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_download_storage.dart';
import '../support/fake_music_source.dart';
import '../support/fakes.dart';

/// 可编排的单曲缓存假件：只覆盖页面消费的两个方法。
class _FakeTrackCacheService extends TrackCacheService {
  _FakeTrackCacheService() : super(
          cacheService: CacheService(storage: MemoryCacheStorage()),
          artworkCache: ArtworkCache(
            cacheService: CacheService(storage: MemoryCacheStorage()),
          ),
          catalogService: CatalogService(
            registry: FakeSourceRegistry(const {}),
          ),
        );

  /// 按曲目 id 返回占用（验证切歌后重载）。
  final Map<String, TrackCacheUsage> usageByTrack = {};
  TrackCacheClearResult nextClear =
      const TrackCacheClearResult(part: TrackCachePart.audio);
  final List<(TrackCachePart, String)> clearCalls = [];

  @override
  Future<TrackCacheUsage> usage(Track track) async =>
      usageByTrack[track.id.uri] ?? const TrackCacheUsage();

  @override
  Future<TrackCacheClearResult> clear(
    Track track,
    TrackCachePart part,
  ) async {
    clearCalls.add((part, track.id.uri));
    return nextClear;
  }
}

/// 可编排的下载服务假件：只覆盖页面消费的状态与动作。
class _FakeDownloadService extends DownloadService {
  _FakeDownloadService()
      : super(
          catalog: CatalogService(registry: FakeSourceRegistry(const {})),
          repository: DownloadsRepository(
            databaseProvider: () => throw UnimplementedError(),
          ),
          storage: FakeDownloadStorage(),
        );

  DownloadedTrack? record;
  DownloadProgress? progress;
  bool downloadSupported = true;
  int downloadCalls = 0;
  int cancelCalls = 0;
  int deleteCalls = 0;

  @override
  bool get supported => downloadSupported;

  @override
  DownloadedTrack? recordForTrack(Track track) => record;

  @override
  DownloadProgress? progressForTrack(Track track) => progress;

  @override
  Future<void> download(Track track) async {
    downloadCalls++;
  }

  @override
  void cancelTrack(Track track) {
    cancelCalls++;
  }

  @override
  Future<void> delete(DownloadedTrack downloaded) async {
    deleteCalls++;
    record = null;
    notifyListeners();
  }
}

Track _track() => const Track(
      id: TrackId('kw', 'a'),
      title: 'Title a',
      artists: [Artist(name: 'Artist a')],
      album: 'Album a',
      duration: Duration(seconds: 245),
      origin: TrackOrigin.lx,
      qualities: [
        AudioQuality(type: '320k', size: '9.8MB'),
        AudioQuality(type: 'flac'),
      ],
      payload: {'id': 'a'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playback;
  late _FakeTrackCacheService cacheService;
  late _FakeDownloadService downloadService;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
    cacheService = _FakeTrackCacheService();
    downloadService = _FakeDownloadService();
  });

  tearDown(() => playback.dispose());

  Future<void> pumpView(
    WidgetTester tester, {
    Track? track,
    DownloadService? downloads,
  }) async {
    backend.emit(BackendSnapshot(
      current: track,
      queue: [if (track != null) track],
      currentIndex: track == null ? -1 : 0,
      duration: track?.duration ?? Duration.zero,
    ));

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          Provider<TrackCacheService>.value(value: cacheService),
          if (downloads != null)
            ChangeNotifierProvider<DownloadService>.value(value: downloads),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(
            body: TrackInfoView(controller: ScrollController()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 列表向下滚动：下载区在缓存区之后，测试视口外不构建。
  Future<void> scrollToBottom(WidgetTester tester) async {
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
  }

  testWidgets('信息区：音质本地化 + 可用音质 + 渠道回退 key + 专辑/时长/ID', (tester) async {
    await pumpView(tester, track: _track());

    expect(find.text('本次播放音质'), findsOneWidget);
    // 无音源列表（未注入 SourcesProvider）：渠道回退原始 key。
    expect(find.text('kw'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('Album a'), findsOneWidget);
    expect(find.text('4:05'), findsOneWidget);
    // 可用音质：本地化名 + 体积（未知类型回退原值）。
    expect(find.text('320K (9.8MB) · 无损'), findsOneWidget);
    // 曲目 ID 行点击复制。
    final copyRow = find.byKey(const Key('trackInfoCopyIdItem'));
    await tester.tap(copyRow);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('渠道展示名回退：未注入音源列表时显示原始 key', (tester) async {
    await pumpView(tester, track: _track());

    expect(find.text('kw'), findsOneWidget);
  });

  testWidgets('缓存区：占用文案 + 清理结果提示 + 逐项调用', (tester) async {
    cacheService.usageByTrack['kw:a'] = const TrackCacheUsage(
      audio: CacheUsage(bytes: 3 * 1024 * 1024, count: 2),
      lyrics: CacheUsage(bytes: 2048, count: 1),
      artwork: CacheUsage(bytes: 0, count: 0),
      resolveEntries: 1,
    );
    cacheService.nextClear = const TrackCacheClearResult(
      part: TrackCachePart.audio,
      freed: CacheUsage(bytes: 3 * 1024 * 1024, count: 2),
    );
    await pumpView(tester, track: _track());

    expect(find.textContaining('3.0 MB'), findsOneWidget);
    expect(find.textContaining('2 KB'), findsOneWidget);
    expect(find.text('无缓存'), findsOneWidget);
    expect(find.text('1 条'), findsOneWidget);

    await tester.tap(find.byKey(const Key('trackInfoCache_audio')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(cacheService.clearCalls, [(TrackCachePart.audio, 'kw:a')]);
    expect(find.text('已清理 3.0 MB'), findsOneWidget);
  });

  testWidgets('缓存区：播放中跳过音频 → 提示稍后再清', (tester) async {
    cacheService.usageByTrack['kw:a'] = const TrackCacheUsage(
      audio: CacheUsage(bytes: 1024, count: 1),
    );
    cacheService.nextClear = const TrackCacheClearResult(
      part: TrackCachePart.audio,
      skipped: 1,
    );
    await pumpView(tester, track: _track());

    await tester.tap(find.byKey(const Key('trackInfoCache_audio')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('正在播放，音频缓存稍后再清'), findsOneWidget);
  });

  testWidgets('切歌：占用按新曲目重载', (tester) async {
    cacheService.usageByTrack['kw:a'] =
        const TrackCacheUsage(audio: CacheUsage(bytes: 1024, count: 1));
    cacheService.usageByTrack['kw:b'] =
        const TrackCacheUsage(audio: CacheUsage(bytes: 5 * 1024 * 1024, count: 3));
    await pumpView(tester, track: _track());
    expect(find.textContaining('1 KB'), findsOneWidget);

    const next = Track(
      id: TrackId('kw', 'b'),
      title: 'Title b',
      origin: TrackOrigin.lx,
      payload: {'id': 'b'},
    );
    backend.emit(const BackendSnapshot(
      current: next,
      queue: [next],
      currentIndex: 0,
      duration: Duration(seconds: 100),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('5.0 MB'), findsOneWidget);
    expect(find.text('kw:b'), findsOneWidget);

    // 通知节流计时器跑完，避免 pending timer 报错。
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('无曲目：空态提示，不显示缓存区', (tester) async {
    await pumpView(tester);

    expect(find.text('暂无播放曲目'), findsOneWidget);
    expect(find.byKey(const Key('trackInfoCache_audio')), findsNothing);
  });

  testWidgets('定时关闭：档位设置与取消（行副标题随状态刷新）', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await pumpView(tester, track: _track());

    expect(find.text('定时关闭'), findsOneWidget);
    expect(find.text('未开启'), findsOneWidget);

    // 定时关闭在下载区之后：先滚进可视区再点。
    await tester.ensureVisible(find.byKey(const Key('trackInfoSleepTimerItem')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('trackInfoSleepTimerItem')));
    await tester.pumpAndSettle();
    expect(find.text('15 分钟后暂停'), findsOneWidget);

    await tester.tap(find.text('15 分钟后暂停'));
    await tester.pumpAndSettle();
    expect(playback.sleepTimer.value.remaining, const Duration(minutes: 15));
    expect(find.text('剩余 15:00'), findsOneWidget);

    // 再开弹层：显示关闭定时 + 当前状态（行副标题与弹层状态行同时可见）。
    await tester.tap(find.byKey(const Key('trackInfoSleepTimerItem')));
    await tester.pumpAndSettle();
    expect(find.text('关闭定时'), findsOneWidget);
    expect(find.text('剩余 15:00'), findsNWidgets(2));
    await tester.tap(find.text('关闭定时'));
    await tester.pumpAndSettle();

    expect(playback.sleepTimer.value.mode, SleepTimerMode.off);
    expect(find.text('未开启'), findsOneWidget);
  });

  testWidgets('定时关闭：空态仍保留入口，「播完当前歌曲」不可用', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await pumpView(tester);

    expect(find.text('暂无播放曲目'), findsOneWidget);
    expect(find.byKey(const Key('trackInfoSleepTimerItem')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('trackInfoSleepTimerItem')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('trackInfoSleepTimerItem')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播完当前歌曲后暂停'));
    await tester.pumpAndSettle();

    expect(playback.sleepTimer.value.mode, SleepTimerMode.off);
  });

  testWidgets('定时关闭：自定义时长校验与设定', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await pumpView(tester, track: _track());

    await tester.ensureVisible(find.byKey(const Key('trackInfoSleepTimerItem')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('trackInfoSleepTimerItem')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义时长…'));
    await tester.pumpAndSettle();

    // 非法输入：给出错误文案，确认键禁用（点击不设定、不关弹窗）。
    await tester.enterText(find.byType(M3ETextField), '0');
    await tester.pumpAndSettle();
    expect(find.text('请输入 1–600 之间的整数'), findsOneWidget);
    await tester.tap(find.text('设定'));
    await tester.pumpAndSettle();
    expect(playback.sleepTimer.value.mode, SleepTimerMode.off);

    await tester.enterText(find.byType(M3ETextField), '25');
    await tester.pumpAndSettle();
    await tester.tap(find.text('设定'));
    await tester.pumpAndSettle();

    expect(playback.sleepTimer.value.remaining, const Duration(minutes: 25));
    expect(find.text('剩余 25:00'), findsOneWidget);
  });

  testWidgets('下载区：未下载 → 点下载触发下载动作', (tester) async {
    await pumpView(tester, track: _track(), downloads: downloadService);
    await scrollToBottom(tester);

    expect(find.text('未下载'), findsOneWidget);
    expect(find.byKey(const Key('trackInfoDownloadStart')), findsOneWidget);

    await tester.tap(find.byKey(const Key('trackInfoDownloadStart')));
    await tester.pump();
    expect(downloadService.downloadCalls, 1);
  });

  testWidgets('下载区：下载中显示百分比 + 取消', (tester) async {
    downloadService.progress = const DownloadProgress(
      receivedBytes: 50,
      totalBytes: 100,
    );
    await pumpView(tester, track: _track(), downloads: downloadService);
    await scrollToBottom(tester);

    expect(find.text('下载中'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    await tester.tap(find.byKey(const Key('trackInfoDownloadCancel')));
    await tester.pump();
    expect(downloadService.cancelCalls, 1);
  });

  testWidgets('下载区：已下载显示大小 + 删除/分享导出', (tester) async {
    downloadService.record = const DownloadedTrack(
      originSourceKey: 'kw',
      originSongId: 'a',
      title: 'Title a',
      filePath: '/downloads/a.mp3',
      quality: '320k',
      sizeBytes: 3 * 1024 * 1024,
      downloadedAt: 1,
    );
    await pumpView(tester, track: _track(), downloads: downloadService);
    await scrollToBottom(tester);

    expect(find.text('已下载'), findsOneWidget);
    expect(find.text('3.0 MB · 320K'), findsOneWidget);
    expect(find.byKey(const Key('trackInfoDownloadShare')), findsOneWidget);

    // 删除需确认：对话框确认后调用删除。
    await tester.tap(find.byKey(const Key('trackInfoDownloadDelete')));
    await tester.pumpAndSettle();
    expect(find.text('删除下载'), findsWidgets);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(downloadService.deleteCalls, 1);
    // 删除后回落到未下载态。
    expect(find.byKey(const Key('trackInfoDownloadStart')), findsOneWidget);
  });

  testWidgets('下载区：平台不支持（Web/存储不可用）时整区隐藏', (tester) async {
    downloadService.downloadSupported = false;
    await pumpView(tester, track: _track(), downloads: downloadService);
    await scrollToBottom(tester);

    expect(find.text('下载'), findsNothing);
    expect(find.byKey(const Key('trackInfoDownloadStart')), findsNothing);
  });

  testWidgets('本地曲目：渠道显示「本地下载」，下载区显示已下载', (tester) async {
    downloadService.record = const DownloadedTrack(
      originSourceKey: 'kw',
      originSongId: 'a',
      title: '本地歌曲',
      filePath: '/downloads/a.mp3',
      sizeBytes: 2048,
      downloadedAt: 1,
    );
    const localTrack = Track(
      id: TrackId('local', 'kw:a'),
      title: '本地歌曲',
      origin: TrackOrigin.localFile,
      payload: {'path': '/downloads/a.mp3', 'songId': 'kw:a'},
    );
    await pumpView(tester, track: localTrack, downloads: downloadService);

    expect(find.text('本地下载'), findsOneWidget);
    await scrollToBottom(tester);
    expect(find.text('已下载'), findsOneWidget);
    expect(find.text('2 KB'), findsOneWidget);
  });

  testWidgets('本地曲目：下载记录已删时提示文件缺失（不显示下载动作）', (tester) async {
    const localTrack = Track(
      id: TrackId('local', 'kw:a'),
      title: '本地歌曲',
      origin: TrackOrigin.localFile,
      payload: {'path': '/downloads/a.mp3', 'songId': 'kw:a'},
    );
    await pumpView(tester, track: localTrack, downloads: downloadService);
    await scrollToBottom(tester);

    expect(find.text('本地文件不存在，可能已被删除'), findsOneWidget);
    expect(find.byKey(const Key('trackInfoDownloadStart')), findsNothing);
  });
}
