import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/downloads/downloads_repository.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/pages/track_cache_page.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/sleep_timer.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage_stub.dart';
import 'package:molia/services/download/download_service.dart';
import 'package:molia/services/track_cache_service.dart';
import 'package:molia/utils/lyrics_provider_label.dart';
import 'package:molia/widgets/track_info_view.dart';
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
  Future<void> download(
    Track track, {
    String? quality,
    bool includeLyrics = true,
    bool includeCover = true,
  }) async {
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
          ChangeNotifierProvider(create: (_) => LyricsProvider()),
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

  /// 列表向下滚动：缓存区在信息区之后，测试视口外不构建。
  Future<void> scrollToBottom(WidgetTester tester) async {
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
  }

  testWidgets('信息区：音质本地化 + 可用音质 + 来源（渠道 · ID）+ 专辑', (tester) async {
    await pumpView(tester, track: _track());

    expect(find.text('本次播放音质'), findsOneWidget);
    // 无音源列表（未注入 SourcesProvider）：来源行回退原始 key + 曲目 ID。
    expect(find.text('kw · kw:a'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('Album a'), findsOneWidget);
    // 时长已从信息卡片移除。
    expect(find.text('4:05'), findsNothing);
    // 可用音质：本地化名 + 体积（未知类型回退原值）。
    expect(find.text('320K (9.8MB) · 无损'), findsOneWidget);
    // 歌词来源：会话未加载时为「暂无歌词」。
    expect(find.text('歌词来源'), findsOneWidget);
    expect(find.text('暂无歌词'), findsOneWidget);
  });

  testWidgets('来源行：打开分享弹层，复制曲目 ID', (tester) async {
    await pumpView(tester, track: _track());

    await tester.tap(find.byKey(const Key('trackInfoSourceItem')));
    await tester.pumpAndSettle();
    expect(find.text('曲目 ID'), findsOneWidget);
    expect(find.text('分享平台页面'), findsOneWidget);
    expect(find.text('打开平台页面'), findsOneWidget);
    // 未下载：文件动作显示「下载并分享」。
    expect(find.text('下载并分享'), findsOneWidget);

    await tester.tap(find.text('曲目 ID'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('曲目 ID 已复制'), findsOneWidget);
  });

  testWidgets('缓存行：汇总副标题 + 打开单曲缓存子页', (tester) async {
    cacheService.usageByTrack['kw:a'] = const TrackCacheUsage(
      audio: CacheUsage(bytes: 3 * 1024 * 1024, count: 2),
      lyrics: CacheUsage(bytes: 2048, count: 1),
      resolveEntries: 1,
    );
    await pumpView(tester, track: _track());
    await scrollToBottom(tester);

    expect(find.text('缓存'), findsOneWidget);
    expect(find.text('音频缓存 3.0 MB · 歌词缓存 2 KB · 取链缓存 1 条'), findsOneWidget);

    await tester.tap(find.byKey(const Key('trackInfoCacheItem')));
    await tester.pumpAndSettle();
    expect(find.byType(TrackCachePage), findsOneWidget);
    expect(find.text('单曲缓存'), findsOneWidget);
  });

  testWidgets('缓存子页：逐项清理需确认，确认后调用清理并提示', (tester) async {
    cacheService.usageByTrack['kw:a'] = const TrackCacheUsage(
      audio: CacheUsage(bytes: 3 * 1024 * 1024, count: 2),
    );
    cacheService.nextClear = const TrackCacheClearResult(
      part: TrackCachePart.audio,
      freed: CacheUsage(bytes: 3 * 1024 * 1024, count: 2),
    );
    await pumpView(tester, track: _track());
    await scrollToBottom(tester);
    await tester.tap(find.byKey(const Key('trackInfoCacheItem')));
    await tester.pumpAndSettle();

    expect(find.text('音频缓存'), findsOneWidget);
    expect(find.text('3.0 MB · 2 项'), findsOneWidget);
    // 未命中的分区清理按钮禁用。
    expect(find.text('清理'), findsWidgets);

    await tester.tap(find.text('清理').first);
    await tester.pumpAndSettle();
    expect(find.text('清理「音频缓存」？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(cacheService.clearCalls, [(TrackCachePart.audio, 'kw:a')]);
    expect(find.text('已清理 3.0 MB'), findsOneWidget);
  });

  testWidgets('切歌：缓存汇总按新曲目重载', (tester) async {
    cacheService.usageByTrack['kw:a'] =
        const TrackCacheUsage(audio: CacheUsage(bytes: 1024, count: 1));
    cacheService.usageByTrack['kw:b'] =
        const TrackCacheUsage(audio: CacheUsage(bytes: 5 * 1024 * 1024, count: 3));
    await pumpView(tester, track: _track());
    await scrollToBottom(tester);
    expect(find.text('音频缓存 1 KB'), findsOneWidget);

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

    expect(find.text('音频缓存 5.0 MB'), findsOneWidget);

    // 通知节流计时器跑完，避免 pending timer 报错。
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('无曲目：空态提示，仅保留定时关闭入口', (tester) async {
    await pumpView(tester);

    expect(find.text('暂无播放曲目'), findsOneWidget);
    expect(find.byKey(const Key('trackInfoCacheItem')), findsNothing);
    expect(find.byKey(const Key('trackInfoDownloadItem')), findsNothing);
    expect(find.byKey(const Key('trackInfoCommentsItem')), findsNothing);
    expect(find.byKey(const Key('trackInfoSleepTimerItem')), findsOneWidget);
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

  testWidgets('下载行：未下载 → 打开弹层 → 点下载触发下载动作', (tester) async {
    await pumpView(tester, track: _track(), downloads: downloadService);

    expect(find.text('下载'), findsOneWidget);
    expect(find.text('未下载'), findsOneWidget);

    await tester.tap(find.byKey(const Key('trackInfoDownloadItem')));
    await tester.pumpAndSettle();
    // 弹层：音频段（音质选项 + 状态 + 下载）+ 附加内容段 + 全部下载。
    expect(find.text('音频'), findsOneWidget);
    expect(find.text('附加内容'), findsOneWidget);
    expect(find.byKey(const Key('downloadQuality_320k')), findsOneWidget);
    expect(find.byKey(const Key('downloadLyricsPart')), findsOneWidget);
    expect(find.byKey(const Key('downloadCoverPart')), findsOneWidget);
    expect(find.byKey(const Key('downloadAll')), findsOneWidget);
    expect(find.byKey(const Key('downloadSheetStart')), findsOneWidget);

    await tester.tap(find.byKey(const Key('downloadSheetStart')));
    await tester.pump();
    expect(downloadService.downloadCalls, 1);
  });

  testWidgets('下载行：下载中显示百分比 + 取消', (tester) async {
    downloadService.progress = const DownloadProgress(
      receivedBytes: 50,
      totalBytes: 100,
    );
    await pumpView(tester, track: _track(), downloads: downloadService);

    expect(find.text('下载中 · 50%'), findsOneWidget);

    await tester.tap(find.byKey(const Key('trackInfoDownloadItem')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('downloadSheetCancel')));
    await tester.pump();
    expect(downloadService.cancelCalls, 1);
  });

  testWidgets('下载行：已下载显示大小 + 弹层删除需确认', (tester) async {
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

    expect(find.text('3.0 MB · 320K'), findsOneWidget);

    await tester.tap(find.byKey(const Key('trackInfoDownloadItem')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('downloadSheetShare')), findsOneWidget);

    await tester.tap(find.byKey(const Key('downloadSheetDelete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(downloadService.deleteCalls, 1);
    // 删除后回落到未下载态。
    expect(find.byKey(const Key('downloadSheetStart')), findsOneWidget);
  });

  testWidgets('下载行：平台不支持（Web/存储不可用）时入口禁用', (tester) async {
    downloadService.downloadSupported = false;
    await pumpView(tester, track: _track(), downloads: downloadService);

    // 行仍在（显示状态），但不支持时无下载服务入口。
    expect(find.byKey(const Key('trackInfoDownloadItem')), findsOneWidget);
  });

  testWidgets('本地曲目：来源显示「本地下载」，下载行显示文件缺失', (tester) async {
    const localTrack = Track(
      id: TrackId('local', 'kw:a'),
      title: '本地歌曲',
      origin: TrackOrigin.localFile,
      payload: {'path': '/downloads/a.mp3', 'songId': 'kw:a'},
    );
    await pumpView(tester, track: localTrack, downloads: downloadService);

    expect(find.text('本地下载 · local:kw:a'), findsOneWidget);
    expect(find.text('本地文件不存在，可能已被删除'), findsOneWidget);
    // 本地曲目没有「换源」入口。
    expect(find.byKey(const Key('trackInfoSourceSwapItem')), findsNothing);
  });

  test('歌词来源展示名：兼容音源 key 与 provider 名', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('zh'));
    expect(lyricsProviderLabel(l10n, const [], 'wy'), '网易云音乐');
    expect(lyricsProviderLabel(l10n, const [], 'netease'), '网易云音乐');
    expect(lyricsProviderLabel(l10n, const [], 'tx'), 'QQ音乐');
    expect(lyricsProviderLabel(l10n, const [], 'lrclib'), 'LRCLIB');
    expect(lyricsProviderLabel(l10n, const [], 'local'), '本地下载');
    expect(lyricsProviderLabel(l10n, const [], 'my_script'), 'my_script');
  });
}
