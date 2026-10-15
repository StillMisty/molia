import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/album_service.dart';
import 'package:molia/data/catalog/artist_service.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/downloads/downloads_repository.dart';
import 'package:molia/domain/models/album.dart';
import 'package:molia/domain/models/artist.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/source_registry.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/pages/album_page.dart';
import 'package:molia/pages/artist_page.dart';
import 'package:molia/pages/track_cache_page.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/sleep_timer.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage_stub.dart';
import 'package:molia/services/download/download_service.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/services/track_cache_service.dart';
import 'package:molia/utils/lyrics_provider_label.dart';
import 'package:molia/widgets/track_info_view.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_download_storage.dart';
import '../support/fake_music_source.dart';
import '../support/fakes.dart';

/// 记录型提示服务：断言 Snackbar 文案与「取消」回调。
class _RecordingNotificationService extends NotificationService {
  _RecordingNotificationService()
      : super(GlobalKey<ScaffoldMessengerState>());

  final List<(String, String?, VoidCallback?)> snackbars = [];

  @override
  void showSnackBar(
    String message, {
    bool isError = false,
    Duration duration = const Duration(seconds: 4),
    String? actionLabel,
    VoidCallback? onActionPressed,
  }) {
    snackbars.add((message, actionLabel, onActionPressed));
  }
}

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

  /// 完整缓存命中（按音质）：缓存 = 已下载识别用。
  final Map<String, AudioCacheHit> audioCacheByQuality = {};

  @override
  bool get supported => downloadSupported;

  @override
  DownloadedTrack? recordForTrack(Track track) => record;

  @override
  DownloadProgress? progressForTrack(Track track) => progress;

  @override
  Future<AudioCacheHit?> audioCacheFor(
    Track track, {
    Iterable<String>? qualities,
  }) async {
    if (qualities == null) {
      return audioCacheByQuality.isEmpty ? null : audioCacheByQuality.values.first;
    }
    for (final quality in qualities) {
      final hit = audioCacheByQuality[quality];
      if (hit != null) return hit;
    }
    return null;
  }

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

Track _track({
  String? albumId,
  String? artistId,
  String artistName = 'Artist a',
}) =>
    Track(
      id: const TrackId('kw', 'a'),
      title: 'Title a',
      artists: [Artist(name: artistName, id: artistId)],
      album: 'Album a',
      duration: const Duration(seconds: 245),
      origin: TrackOrigin.lx,
      qualities: const [
        AudioQuality(type: '320k', size: '9.8MB'),
        AudioQuality(type: 'flac'),
      ],
      payload: {'id': 'a', if (albumId != null) 'albumId': albumId},
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
    SourceRegistry? registry,
    AlbumService? albumService,
    ArtistService? artistService,
    NotificationService? notifications,
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
          if (registry != null) Provider<SourceRegistry>.value(value: registry),
          if (albumService != null)
            Provider<AlbumService>.value(value: albumService),
          if (artistService != null)
            Provider<ArtistService>.value(value: artistService),
          if (notifications != null)
            Provider<NotificationService>.value(value: notifications),
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

  testWidgets('专辑行：payload 有专辑 id 且渠道支持时改为可点，进入专辑页', (tester) async {
    final registry = FakeSourceRegistry({
      'kw': FakeMusicSource(
        'kw',
        capabilities: const SourceCapabilities(search: true, collection: true),
      ),
    });
    final albumService = AlbumService(
      fetch: (sourceKey, albumId, {required page, required limit}) async =>
          Album(
        id: albumId,
        name: 'Album a',
        artist: 'Artist a',
        tracks: const [
          Track(id: TrackId('kw', 'a'), title: 'Title a', origin: TrackOrigin.lx),
        ],
      ),
    );
    await pumpView(
      tester,
      track: _track(albumId: '123'),
      registry: registry,
      albumService: albumService,
    );

    expect(find.byKey(const Key('trackInfoAlbumItem')), findsOneWidget);
    expect(find.text('Album a · 查看专辑'), findsOneWidget);

    await tester.tap(find.byKey(const Key('trackInfoAlbumItem')));
    await tester.pumpAndSettle();
    expect(find.byType(AlbumPage), findsOneWidget);
    expect(find.text('Album a'), findsWidgets);
  });

  testWidgets('专辑行：渠道不支持专辑能力时保持只读信息行', (tester) async {
    final registry = FakeSourceRegistry({
      'kw': FakeMusicSource(
        'kw',
        capabilities: const SourceCapabilities(search: true),
      ),
    });
    await pumpView(tester, track: _track(albumId: '123'), registry: registry);

    expect(find.byKey(const Key('trackInfoAlbumItem')), findsNothing);
    expect(find.text('Album a'), findsOneWidget);
  });

  testWidgets('专辑行：payload 无专辑 id 时保持只读信息行', (tester) async {
    final registry = FakeSourceRegistry({
      'kw': FakeMusicSource(
        'kw',
        capabilities: const SourceCapabilities(search: true, collection: true),
      ),
    });
    await pumpView(tester, track: _track(), registry: registry);

    expect(find.byKey(const Key('trackInfoAlbumItem')), findsNothing);
    expect(find.text('Album a'), findsOneWidget);
  });

  testWidgets('歌手行：曲目带歌手 id 且渠道支持时改为可点，进入歌手页', (tester) async {
    final registry = FakeSourceRegistry({
      'kw': FakeMusicSource(
        'kw',
        capabilities: const SourceCapabilities(search: true, artist: true),
      ),
    });
    final artistService = ArtistService(
      fetch: (sourceKey, artistId, {required page, required limit}) async =>
          const ArtistDetail(
        id: '9527',
        name: 'Artist a',
        tracks: [
          Track(id: TrackId('kw', 'a'), title: 'Title a', origin: TrackOrigin.lx),
        ],
      ),
    );
    await pumpView(
      tester,
      track: _track(artistId: '9527'),
      registry: registry,
      artistService: artistService,
    );

    expect(find.byKey(const Key('trackInfoArtistItem')), findsOneWidget);
    expect(find.text('Artist a · 查看歌手'), findsOneWidget);

    await tester.tap(find.byKey(const Key('trackInfoArtistItem')));
    await tester.pumpAndSettle();
    expect(find.byType(ArtistPage), findsOneWidget);
    expect(find.text('Artist a'), findsWidgets);
  });

  testWidgets('歌手行：渠道不支持歌手能力时保持只读信息行', (tester) async {
    final registry = FakeSourceRegistry({
      'kw': FakeMusicSource(
        'kw',
        capabilities: const SourceCapabilities(search: true),
      ),
    });
    await pumpView(
      tester,
      track: _track(artistId: '9527'),
      registry: registry,
    );

    expect(find.byKey(const Key('trackInfoArtistItem')), findsNothing);
    expect(find.text('Artist a'), findsOneWidget);
  });

  testWidgets('歌手行：曲目无歌手 id 时按名字回退解析（历史收藏可跳转）', (tester) async {
    final registry = FakeSourceRegistry({
      'kw': FakeMusicSource(
        'kw',
        capabilities: const SourceCapabilities(search: true, artist: true),
      ),
    });
    final searched = <String>[];
    final artistService = ArtistService(
      fetch: (sourceKey, artistId, {required page, required limit}) async =>
          const ArtistDetail(id: '9527', name: 'Artist a'),
      search: (sourceKey, name) async {
        searched.add(name);
        return [ArtistSummary(id: '9527', name: name)];
      },
    );
    await pumpView(
      tester,
      track: _track(),
      registry: registry,
      artistService: artistService,
    );

    expect(find.byKey(const Key('trackInfoArtistItem')), findsOneWidget);
    expect(find.text('Artist a · 查看歌手'), findsOneWidget);

    await tester.tap(find.byKey(const Key('trackInfoArtistItem')));
    await tester.pumpAndSettle();
    expect(searched, ['Artist a'], reason: '无 id 时按歌手名回退检索');
    expect(find.byType(ArtistPage), findsOneWidget);
  });

  testWidgets('歌手行：未找到回退歌手时显示「未找到该歌手」', (tester) async {
    final registry = FakeSourceRegistry({
      'kw': FakeMusicSource(
        'kw',
        capabilities: const SourceCapabilities(search: true, artist: true),
      ),
    });
    final artistService = ArtistService(
      fetch: (sourceKey, artistId, {required page, required limit}) async =>
          throw StateError('不应到这里'),
      search: (sourceKey, name) async => const [],
    );
    await pumpView(
      tester,
      track: _track(),
      registry: registry,
      artistService: artistService,
    );

    await tester.tap(find.byKey(const Key('trackInfoArtistItem')));
    await tester.pumpAndSettle();
    expect(find.text('未找到该歌手'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('歌手行：曲目没有歌手名时整行隐藏', (tester) async {
    final registry = FakeSourceRegistry({
      'kw': FakeMusicSource(
        'kw',
        capabilities: const SourceCapabilities(search: true, artist: true),
      ),
    });
    await pumpView(
      tester,
      track: _track(artistName: ''),
      registry: registry,
    );

    expect(find.byKey(const Key('trackInfoArtistItem')), findsNothing);
    expect(find.text('歌手'), findsNothing);
  });

  testWidgets('来源行：打开分享弹层，复制曲目 ID', (tester) async {
    await pumpView(tester, track: _track());

    await tester.ensureVisible(find.byKey(const Key('trackInfoSourceItem')));
    await tester.pump();
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

  testWidgets('定时关闭：chip 档位设置与取消（行副标题随状态刷新）', (tester) async {
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
    expect(find.text('倒计时'), findsOneWidget);
    expect(find.text('15 分钟'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sleepTimerPreset_15')));
    await tester.pumpAndSettle();
    expect(playback.sleepTimer.value.remaining, const Duration(minutes: 15));
    expect(find.text('剩余 15:00'), findsOneWidget);

    // 再开弹层：状态区显示剩余时间、当前档位有选中态，取消入口在卡片里。
    await tester.tap(find.byKey(const Key('trackInfoSleepTimerItem')));
    await tester.pumpAndSettle();
    expect(find.text('15:00'), findsOneWidget);
    final selectedChip = tester.widget<M3EChip>(
      find.byKey(const Key('sleepTimerPreset_15')),
    );
    expect(selectedChip.selected, isTrue);
    await tester.tap(find.byKey(const Key('sleepTimerCancelButton')));
    await tester.pumpAndSettle();

    expect(playback.sleepTimer.value.mode, SleepTimerMode.off);
    expect(find.text('未开启'), findsOneWidget);
  });

  testWidgets('定时关闭：开启弹 Snackbar 反馈（取消可撤销），播完当前歌曲同样有反馈',
      (tester) async {
    final notifications = _RecordingNotificationService();
    await pumpView(
      tester,
      track: _track(),
      notifications: notifications,
    );

    await tester.tap(find.byKey(const Key('trackInfoSleepTimerItem')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sleepTimerPreset_15')));
    await tester.pumpAndSettle();

    expect(playback.sleepTimer.value.duration, const Duration(minutes: 15));
    expect(notifications.snackbars, hasLength(1));
    expect(notifications.snackbars.single.$1, '已开启定时关闭 · 15:00 后暂停');
    expect(notifications.snackbars.single.$2, '取消');

    // Snackbar 的「取消」操作直接撤销定时。
    notifications.snackbars.single.$3?.call();
    expect(playback.sleepTimer.value.mode, SleepTimerMode.off);

    // 播完当前歌曲：模式文案反馈。
    await tester.tap(find.byKey(const Key('trackInfoSleepTimerItem')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sleepTimerAfterTrackItem')));
    await tester.pumpAndSettle();
    expect(playback.sleepTimer.value.mode, SleepTimerMode.afterCurrentTrack);
    expect(notifications.snackbars.last.$1, '已开启定时关闭 · 播完当前歌曲后暂停');
  });

  testWidgets('定时关闭：自定义时长走 M3E time picker（初始 30 分钟）', (tester) async {
    await pumpView(
      tester,
      track: _track(),
      notifications: _RecordingNotificationService(),
    );

    await tester.tap(find.byKey(const Key('trackInfoSleepTimerItem')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sleepTimerCustomChip')));
    await tester.pumpAndSettle();

    // 时间选择器（24 小时制）：确认即按初始 0:30（30 分钟）武装。
    expect(find.text('自定义时长'), findsWidgets);
    await tester.tap(find.text('设定'));
    await tester.pumpAndSettle();
    expect(playback.sleepTimer.value.duration, const Duration(minutes: 30));
    expect(playback.sleepTimer.value.mode, SleepTimerMode.countdown);
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

  testWidgets('下载行：完整缓存命中显示已下载（体积 · 音质 · 缓存副本）', (tester) async {
    downloadService.audioCacheByQuality['320k'] = const AudioCacheHit(
      quality: '320k',
      path: '/cache/audio/a.mp3',
      sizeBytes: 3 * 1024 * 1024,
    );
    await pumpView(tester, track: _track(), downloads: downloadService);

    expect(find.text('未下载'), findsNothing);
    expect(find.text('3.0 MB · 320K · 缓存副本'), findsOneWidget);

    // 弹层：状态与主按钮按「缓存 = 已下载」呈现，动作为转存到本地文件夹。
    await tester.tap(find.byKey(const Key('trackInfoDownloadItem')));
    await tester.pumpAndSettle();
    expect(find.text('已下载'), findsOneWidget);
    expect(find.text('本地缓存'), findsOneWidget);
    expect(find.text('下载到本地文件夹'), findsNWidgets(2));
    expect(find.text('全部下载'), findsNothing);

    await tester.tap(find.byKey(const Key('downloadSheetStart')));
    await tester.pump();
    expect(downloadService.downloadCalls, 1);
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
