import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
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
import 'package:molia/pages/track_local_data_page.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/sleep_timer.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/covers/custom_cover_store.dart';

import '../support/memory_cache_storage.dart';

import 'package:molia/services/download/download_service.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/services/track_local_data_service.dart';
import 'package:molia/utils/lyrics_provider_label.dart';
import 'package:molia/widgets/app_network_image.dart';
import 'package:molia/widgets/settings/settings_tiles.dart';
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

/// 可编排的单曲本地数据假件：数据来自假下载服务记录 + 各分项占用表。
class _FakeLocalDataService extends TrackLocalDataService {
  _FakeLocalDataService({required this.downloads})
      : super(
          cacheService: CacheService(storage: MemoryCacheStorage()),
          artworkCache: ArtworkCache(
            cacheService: CacheService(storage: MemoryCacheStorage()),
          ),
          catalogService:
              CatalogService(registry: FakeSourceRegistry(const {})),
        );

  final _FakeDownloadService downloads;

  /// 按曲目 id 编排缓存（验证两档状态与切歌后重载）。
  final Map<String, CacheUsage> audioCacheByTrack = {};
  final Map<String, CacheUsage> audioWritingByTrack = {};
  final Map<String, CacheUsage> lyricsCacheByTrack = {};
  final Map<String, CacheUsage> artworkCacheByTrack = {};
  final Map<String, List<String>> cachedQualitiesByTrack = {};
  final Map<String, int> resolveByTrack = {};

  LocalCacheClearResult nextClear = const LocalCacheClearResult(
    part: LocalCachePart.audio,
  );
  final List<(LocalCachePart, String)> clearCalls = [];

  /// load 调用次数与曲目（防抖 / 单飞断言用）。
  int loadCalls = 0;
  final List<TrackId> loadedTracks = [];

  /// 非空时 load 挂起，直到测试放行（单飞测试用）。
  Completer<void>? loadGate;

  @override
  TrackLocalData downloadState(Track track) =>
      TrackLocalData(download: downloads.record);

  @override
  Future<TrackLocalData> load(Track track) async {
    loadCalls++;
    loadedTracks.add(track.id);
    final gate = loadGate;
    if (gate != null) await gate.future;
    return TrackLocalData(
      download: downloads.record,
      audioCache: audioCacheByTrack[track.id.uri] ?? CacheUsage.zero,
      audioWriting: audioWritingByTrack[track.id.uri] ?? CacheUsage.zero,
      lyricsCache: lyricsCacheByTrack[track.id.uri] ?? CacheUsage.zero,
      artworkCache: artworkCacheByTrack[track.id.uri] ?? CacheUsage.zero,
      cachedQualities: cachedQualitiesByTrack[track.id.uri] ?? const [],
      resolveEntries: resolveByTrack[track.id.uri] ?? 0,
    );
  }

  @override
  Future<LocalCacheClearResult> clear(Track track, LocalCachePart part) async {
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

  /// 模拟一次下载进度通知（与真实服务一样走 notifyListeners）。
  void emitProgress(DownloadProgress next) {
    progress = next;
    notifyListeners();
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
  String? artworkUrl,
}) =>
    Track(
      id: const TrackId('kw', 'a'),
      title: 'Title a',
      artists: [Artist(name: artistName, id: artistId)],
      album: 'Album a',
      duration: const Duration(seconds: 245),
      origin: TrackOrigin.lx,
      artwork: artworkUrl == null ? null : Artwork(uri: Uri.parse(artworkUrl)),
      qualities: const [
        AudioQuality(type: '320k', size: '9.8MB'),
        AudioQuality(type: 'flac'),
      ],
      payload: {'id': 'a', 'albumId': ?albumId},
      platformAlbumId: albumId,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playback;
  late _FakeDownloadService downloadService;
  late _FakeLocalDataService localDataService;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
    downloadService = _FakeDownloadService();
    localDataService = _FakeLocalDataService(downloads: downloadService);
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
    backend.emit(
      BackendSnapshot(
        current: track,
        queue: [?track],
        currentIndex: track == null ? -1 : 0,
        duration: track?.duration ?? Duration.zero,
      ),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          ChangeNotifierProvider(create: (_) => LyricsProvider()),
          Provider<TrackLocalDataService>.value(value: localDataService),
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
          home: Scaffold(body: TrackInfoView(controller: ScrollController())),
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

  /// 「本地数据」页向下滚动：缓存占用段在视口外。
  Future<void> scrollLocalDataPage(WidgetTester tester) async {
    await tester.drag(
      find.descendant(
        of: find.byType(TrackLocalDataPage),
        matching: find.byType(Scrollable),
      ),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
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

  testWidgets('封面行：跟随歌曲 → 自定义后立即显示已自定义', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'molia_track_info_cover_',
    );
    final store = CustomCoverStore(
      supportDirectory: () async => tempDir,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
    );
    await tester.runAsync(store.load);
    CustomCoverStore.overrideInstance(store);
    addTearDown(() {
      CustomCoverStore.overrideInstance(null);
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    await pumpView(tester, track: _track());
    final l10n = lookupAppLocalizations(const Locale('zh'));
    expect(find.byKey(const Key('trackInfoCoverItem')), findsOneWidget);
    expect(find.text(l10n.coverTitle), findsOneWidget);
    expect(find.text('跟随歌曲'), findsOneWidget);

    final source = image.Image(width: 2, height: 2);
    await tester.runAsync(
      () => store.setTrackCover(
        const TrackId('kw', 'a'),
        Uint8List.fromList(image.encodePng(source)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已自定义'), findsOneWidget);
  });

  testWidgets('封面行：默认封面只作远端封面的加载失败回退', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'molia_track_info_fallback_',
    );
    final store = CustomCoverStore(
      supportDirectory: () async => tempDir,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
    );
    await tester.runAsync(store.load);
    CustomCoverStore.overrideInstance(store);
    addTearDown(() {
      CustomCoverStore.overrideInstance(null);
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    const remote = 'https://example.com/song-cover.jpg';
    final source = image.Image(width: 2, height: 2);
    await tester.runAsync(
      () => store.setDefaultCover(Uint8List.fromList(image.encodePng(source))),
    );

    await pumpView(tester, track: _track(artworkUrl: remote));

    final thumbnail = tester.widget<AppNetworkImage>(
      find.descendant(
        of: find.byKey(const Key('trackInfoCoverItem')),
        matching: find.byType(AppNetworkImage),
      ),
    );
    expect(thumbnail.url, remote, reason: '主图是歌曲封面，不是默认封面');
    expect(
      thumbnail.fallbackUrl,
      store.defaultCoverUrl,
      reason: '远端封面加载失败时落到默认封面',
    );
  });

  testWidgets('封面行：有真实封面时打开原图查看器（contain + 可换封面）', (tester) async {
    await pumpView(
      tester,
      track: _track(artworkUrl: 'file:///tmp/song-cover.jpg'),
    );
    await tester.tap(find.byKey(const Key('trackInfoCoverItem')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('coverViewerPage')), findsOneWidget);
    final image = tester.widget<AppNetworkImage>(
      find.byKey(const Key('coverViewerImage')),
    );
    expect(image.fit, BoxFit.contain);
    expect(find.byKey(const Key('coverViewerEditButton')), findsOneWidget);
  });

  testWidgets('封面行：查看器「更换封面」进入封面选择弹层', (tester) async {
    await pumpView(
      tester,
      track: _track(artworkUrl: 'file:///tmp/song-cover.jpg'),
    );
    await tester.tap(find.byKey(const Key('trackInfoCoverItem')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('coverViewerEditButton')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('coverViewerPage')), findsNothing);
    expect(find.byKey(const Key('coverPickerChooseButton')), findsOneWidget);
  });

  testWidgets('封面行：没有真实封面时仍打开封面选择弹层', (tester) async {
    await pumpView(tester, track: _track());
    await tester.tap(find.byKey(const Key('trackInfoCoverItem')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('coverViewerPage')), findsNothing);
    expect(find.byKey(const Key('coverPickerChooseButton')), findsOneWidget);
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
          Track(
            id: TrackId('kw', 'a'),
            title: 'Title a',
            origin: TrackOrigin.lx,
          ),
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

    await tester.ensureVisible(find.byKey(const Key('trackInfoAlbumItem')));
    await tester.pumpAndSettle();
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
    await pumpView(
      tester,
      track: _track(albumId: '123'),
      registry: registry,
    );

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
          Track(
            id: TrackId('kw', 'a'),
            title: 'Title a',
            origin: TrackOrigin.lx,
          ),
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

  testWidgets('歌手行：曲目无歌手 id 时保持只读信息行', (tester) async {
    final registry = FakeSourceRegistry({
      'kw': FakeMusicSource(
        'kw',
        capabilities: const SourceCapabilities(search: true, artist: true),
      ),
    });
    await pumpView(tester, track: _track(), registry: registry);

    expect(find.byKey(const Key('trackInfoArtistItem')), findsNothing);
    expect(find.text('Artist a'), findsOneWidget);
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

  testWidgets('本地数据行：两档汇总副标题 + 打开本地数据页', (tester) async {
    localDataService.audioCacheByTrack['kw:a'] = const CacheUsage(
      bytes: 3 * 1024 * 1024,
      count: 2,
    );
    localDataService.cachedQualitiesByTrack['kw:a'] = const ['320k'];
    localDataService.lyricsCacheByTrack['kw:a'] = const CacheUsage(
      bytes: 2048,
      count: 1,
    );
    await pumpView(tester, track: _track());
    await scrollToBottom(tester);

    expect(find.text('本地数据'), findsOneWidget);
    expect(find.text('已缓存 · 320K · 3.0 MB · 可离线使用'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('trackInfoLocalDataItem')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trackInfoLocalDataItem')));
    await tester.pumpAndSettle();
    expect(find.byType(TrackLocalDataPage), findsOneWidget);
  });

  testWidgets('本地数据行：只有歌词缓存时列出分区，不误报音频状态', (tester) async {
    localDataService.lyricsCacheByTrack['kw:a'] = const CacheUsage(
      bytes: 2048,
      count: 1,
    );
    await pumpView(tester, track: _track());
    await scrollToBottom(tester);

    expect(find.text('歌词 已缓存'), findsOneWidget);
  });

  testWidgets('本地数据页：逐项清理需确认，确认后调用清理并提示', (tester) async {
    localDataService.audioCacheByTrack['kw:a'] = const CacheUsage(
      bytes: 3 * 1024 * 1024,
      count: 2,
    );
    localDataService.nextClear = const LocalCacheClearResult(
      part: LocalCachePart.audio,
      freed: CacheUsage(bytes: 3 * 1024 * 1024, count: 2),
    );
    await pumpView(tester, track: _track());
    await scrollToBottom(tester);
    await tester.ensureVisible(find.byKey(const Key('trackInfoLocalDataItem')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trackInfoLocalDataItem')));
    await tester.pumpAndSettle();
    await scrollLocalDataPage(tester);

    expect(find.text('音频缓存'), findsOneWidget);
    expect(find.text('3.0 MB · 2 项'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('清理「音频缓存」？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(localDataService.clearCalls, [(LocalCachePart.audio, 'kw:a')]);
    expect(find.text('已清理 3.0 MB'), findsOneWidget);
  });

  testWidgets('切歌：本地数据汇总按新曲目重载', (tester) async {
    localDataService.audioCacheByTrack['kw:a'] = const CacheUsage(
      bytes: 1024,
      count: 1,
    );
    localDataService.audioCacheByTrack['kw:b'] = const CacheUsage(
      bytes: 5 * 1024 * 1024,
      count: 3,
    );
    await pumpView(tester, track: _track());
    await scrollToBottom(tester);
    expect(find.text('已缓存 · 1 KB · 可离线使用'), findsOneWidget);

    const next = Track(
      id: TrackId('kw', 'b'),
      title: 'Title b',
      origin: TrackOrigin.lx,
      payload: {'id': 'b'},
    );
    backend.emit(
      const BackendSnapshot(
        current: next,
        queue: [next],
        currentIndex: 0,
        duration: Duration(seconds: 100),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('已缓存 · 5.0 MB · 可离线使用'), findsOneWidget);

    // 通知节流计时器跑完，避免 pending timer 报错。
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('无曲目：空态提示，仅保留定时关闭入口', (tester) async {
    await pumpView(tester);

    expect(find.text('暂无播放曲目'), findsOneWidget);
    expect(find.byKey(const Key('trackInfoLocalDataItem')), findsNothing);
    expect(find.byKey(const Key('trackInfoCommentsItem')), findsNothing);
    expect(find.byKey(const Key('trackInfoSleepTimerItem')), findsOneWidget);
  });

  testWidgets('定时关闭：自定义时长设置与关闭（行副标题随状态刷新）', (tester) async {
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
    // 无预设 chips，时长只经自定义入口设置。
    expect(find.byKey(const Key('sleepTimerCustomItem')), findsOneWidget);
    expect(find.byKey(const Key('sleepTimerPreset_15')), findsNothing);

    await tester.tap(find.byKey(const Key('sleepTimerCustomItem')));
    await tester.pumpAndSettle();
    expect(find.text('自定义时长'), findsWidgets);
    await tester.tap(find.text('设定'));
    await tester.pumpAndSettle();
    expect(playback.sleepTimer.value.remaining, const Duration(minutes: 30));
    expect(find.text('剩余 30:00'), findsOneWidget);

    // 再开弹层：状态区显示剩余时间、自定义行选中并带当前时长，取消入口在底部。
    await tester.tap(find.byKey(const Key('trackInfoSleepTimerItem')));
    await tester.pumpAndSettle();
    expect(find.text('30:00'), findsOneWidget);
    final customItem = tester.widget<M3EListItem>(
      find.byKey(const Key('sleepTimerCustomItem')),
    );
    expect(customItem.selected, isTrue);
    await tester.tap(find.byKey(const Key('sleepTimerCancelButton')));
    await tester.pumpAndSettle();

    expect(playback.sleepTimer.value.mode, SleepTimerMode.off);
    expect(find.text('未开启'), findsOneWidget);
  });

  testWidgets('定时关闭：开启弹 Snackbar 反馈（取消可撤销），播完当前歌曲同样有反馈', (tester) async {
    final notifications = _RecordingNotificationService();
    await pumpView(tester, track: _track(), notifications: notifications);

    await tester.tap(find.byKey(const Key('trackInfoSleepTimerItem')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sleepTimerCustomItem')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设定'));
    await tester.pumpAndSettle();

    expect(playback.sleepTimer.value.duration, const Duration(minutes: 30));
    expect(notifications.snackbars, hasLength(1));
    expect(notifications.snackbars.single.$1, '已开启定时关闭 · 30:00 后暂停');
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
    await tester.tap(find.byKey(const Key('sleepTimerCustomItem')));
    await tester.pumpAndSettle();

    // 必须是 M3E time pickers 组件（表盘入口），不是 Material showTimePicker。
    expect(find.byType(M3ETimePickerDialog), findsOneWidget);
    expect(find.byType(M3EDialTimePicker), findsOneWidget);

    // 时间选择器（24 小时制）：确认即按初始 0:30（30 分钟）武装。
    expect(find.text('自定义时长'), findsWidgets);
    await tester.tap(find.text('设定'));
    await tester.pumpAndSettle();
    expect(playback.sleepTimer.value.duration, const Duration(minutes: 30));
    expect(playback.sleepTimer.value.mode, SleepTimerMode.countdown);
  });

  testWidgets('本地数据页：未下载 → 打开页 → 点下载触发下载动作', (tester) async {
    await pumpView(tester, track: _track(), downloads: downloadService);

    expect(find.text('本地数据'), findsOneWidget);
    expect(find.text('未下载'), findsOneWidget);

    await tester.tap(find.byKey(const Key('trackInfoLocalDataItem')));
    await tester.pumpAndSettle();
    // 页内：音频段（音质 + 状态 + 下载）+ 附加内容段 + 缓存占用段。
    expect(find.text('音频'), findsOneWidget);
    expect(find.text('附加内容'), findsOneWidget);
    expect(find.byKey(const Key('localDataQuality_320k')), findsOneWidget);
    expect(find.byKey(const Key('localDataLyricsPart')), findsOneWidget);
    expect(find.byKey(const Key('localDataCoverPart')), findsOneWidget);
    expect(find.byKey(const Key('localDataAudioStatus')), findsOneWidget);
    expect(find.byKey(const Key('localDataDownloadAudio')), findsOneWidget);

    await tester.tap(find.byKey(const Key('localDataDownloadAudio')));
    await tester.pump();
    expect(downloadService.downloadCalls, 1);

    await scrollLocalDataPage(tester);
    expect(find.text('缓存占用'), findsOneWidget);
  });

  testWidgets('本地数据页：下载中显示百分比 + 取消', (tester) async {
    downloadService.progress = const DownloadProgress(
      receivedBytes: 50,
      totalBytes: 100,
    );
    await pumpView(tester, track: _track(), downloads: downloadService);

    expect(find.text('已缓存 · 50%'), findsNothing);
    await tester.tap(find.byKey(const Key('trackInfoLocalDataItem')));
    await tester.pumpAndSettle();
    expect(find.text('下载中 · 50%'), findsOneWidget);

    await tester.tap(find.byKey(const Key('localDataCancel')));
    await tester.pump();
    expect(downloadService.cancelCalls, 1);
  });

  testWidgets('下载进度：快速通知合并为一次防抖重载，切歌立即重载', (tester) async {
    await pumpView(tester, track: _track(), downloads: downloadService);
    final initialLoads = localDataService.loadCalls;

    // 连续进度通知（真实服务按时间节流后仍可能约 10Hz）。
    for (var i = 0; i < 10; i++) {
      downloadService.emitProgress(
        DownloadProgress(receivedBytes: i * 10, totalBytes: 1000),
      );
    }
    await tester.pump(const Duration(milliseconds: 299));
    expect(localDataService.loadCalls, initialLoads, reason: '防抖窗口内不重载');
    await tester.pump(const Duration(milliseconds: 1));
    expect(localDataService.loadCalls, initialLoads + 1, reason: '窗口结束只补一次');
    await tester.pump(const Duration(milliseconds: 300));
    expect(localDataService.loadCalls, initialLoads + 1, reason: '不重复重载');

    // 防抖未到期时切歌：取消待执行重载，新曲目立即重算。
    downloadService.emitProgress(
      const DownloadProgress(receivedBytes: 1, totalBytes: 1000),
    );
    const next = Track(
      id: TrackId('kw', 'b'),
      title: 'Title b',
      origin: TrackOrigin.lx,
      payload: {'id': 'b'},
    );
    backend.emit(
      const BackendSnapshot(
        current: next,
        queue: [next],
        currentIndex: 0,
        duration: Duration(seconds: 100),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(localDataService.loadCalls, initialLoads + 2, reason: '切歌立即重载');
    expect(localDataService.loadedTracks.last, const TrackId('kw', 'b'));

    await tester.pump(const Duration(milliseconds: 300));
    expect(localDataService.loadCalls, initialLoads + 2, reason: '切歌已取消防抖重载');
  });

  testWidgets('本地数据加载单飞：进行中再触发只补一次尾随重载（取最新曲目）', (tester) async {
    await pumpView(tester, track: _track(), downloads: downloadService);
    final initialLoads = localDataService.loadCalls;
    final gate = Completer<void>();
    localDataService.loadGate = gate;

    // 防抖到期进入加载（挂起，模拟慢磁盘扫描）。
    downloadService.emitProgress(
      const DownloadProgress(receivedBytes: 1, totalBytes: 1000),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(localDataService.loadCalls, initialLoads + 1);

    // 加载中再触发多次 + 切歌：不并发，只记一次尾随。
    for (var i = 0; i < 5; i++) {
      downloadService.emitProgress(
        DownloadProgress(receivedBytes: 10 + i, totalBytes: 1000),
      );
    }
    const next = Track(
      id: TrackId('kw', 'b'),
      title: 'Title b',
      origin: TrackOrigin.lx,
      payload: {'id': 'b'},
    );
    backend.emit(
      const BackendSnapshot(
        current: next,
        queue: [next],
        currentIndex: 0,
        duration: Duration(seconds: 100),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(localDataService.loadCalls, initialLoads + 1, reason: '加载中不并发扫描');

    // 放行后恰好补跑一次，且用的是最新当前曲目。
    localDataService.loadGate = null;
    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(localDataService.loadCalls, initialLoads + 2, reason: '只补一次');
    expect(localDataService.loadedTracks.last, const TrackId('kw', 'b'));
  });

  testWidgets('本地数据页：已下载显示大小 + 删除需确认', (tester) async {
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

    expect(find.text('已下载 · 320K · 3.0 MB'), findsOneWidget);

    await tester.tap(find.byKey(const Key('trackInfoLocalDataItem')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('localDataShare')), findsOneWidget);

    await tester.tap(find.byKey(const Key('localDataDeleteDownload')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(downloadService.deleteCalls, 1);
    // 删除后回落到未下载态。
    expect(find.byKey(const Key('localDataDownloadAudio')), findsOneWidget);
  });

  testWidgets('本地数据行：存储不可用（无文件系统）时入口禁用', (tester) async {
    downloadService.downloadSupported = false;
    await pumpView(tester, track: _track(), downloads: downloadService);

    // 行仍在（显示状态），但不支持时页内下载动作禁用。
    expect(find.byKey(const Key('trackInfoLocalDataItem')), findsOneWidget);
    await tester.tap(find.byKey(const Key('trackInfoLocalDataItem')));
    await tester.pumpAndSettle();
    final action = tester.widget<SettingsNavTile>(
      find.byKey(const Key('localDataDownloadAudio')),
    );
    expect(action.onTap, isNull);
  });

  testWidgets('本地数据页：完整缓存命中按「已缓存」呈现，动作是转存', (tester) async {
    localDataService.audioCacheByTrack['kw:a'] = const CacheUsage(
      bytes: 3 * 1024 * 1024,
      count: 1,
    );
    localDataService.cachedQualitiesByTrack['kw:a'] = const ['320k'];
    await pumpView(tester, track: _track(), downloads: downloadService);

    // 缓存不是下载：行副标题说「已缓存」，不说「已下载」。
    expect(find.text('已下载 · 320K · 3.0 MB'), findsNothing);
    expect(find.text('已缓存 · 320K · 3.0 MB · 可离线使用'), findsOneWidget);

    await tester.tap(find.byKey(const Key('trackInfoLocalDataItem')));
    await tester.pumpAndSettle();
    expect(find.text('已缓存'), findsWidgets);
    expect(find.text('已缓存 · 320K · 3.0 MB · 可离线使用'), findsWidgets);
    // 命中缓存的音质带标记；动作为转存（拷缓存，不触网）。
    expect(find.text('转存到本地文件夹'), findsOneWidget);

    await tester.tap(find.byKey(const Key('localDataDownloadAudio')));
    await tester.pump();
    expect(downloadService.downloadCalls, 1);
  });

  testWidgets('本地曲目：来源显示「本地下载」，本地数据行显示文件缺失', (tester) async {
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
