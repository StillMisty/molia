import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage_stub.dart';
import 'package:molia/services/track_cache_service.dart';
import 'package:molia/widgets/track_info_view.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
    cacheService = _FakeTrackCacheService();
  });

  tearDown(() => playback.dispose());

  Future<void> pumpView(
    WidgetTester tester, {
    Track? track,
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
}
