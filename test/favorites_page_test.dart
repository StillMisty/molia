import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/downloads/downloads_repository.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/pages/favorites.dart';
import 'package:molia/providers/discover_provider.dart';
import 'package:molia/providers/library_collections.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/audio_cache_store.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage.dart';
import 'package:molia/services/download/download_service.dart';
import 'package:molia/services/track_local_data_service.dart';
import 'package:molia/utils/responsive.dart';
import 'package:molia/utils/sync_format.dart';
import 'package:molia/widgets/app_search_bar.dart';
import 'package:molia/widgets/empty_state.dart';
import 'package:molia/widgets/shell_reselect.dart';
import 'package:molia/widgets/swipe_reveal_row.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:molia/widgets/track_table_header.dart';
import 'package:material_3_expressive/components/bottom_sheets/components/m3e_bottom_sheet_surface.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_discover_api.dart';
import 'support/fake_download_storage.dart';
import 'support/fake_library_repository.dart';
import 'support/fake_music_source.dart';
import 'support/fakes.dart';
import 'support/memory_cache_storage.dart';

/// 下载服务桩：验证收藏页「本地歌曲」合集的显隐、列表与删除动作。
class _StubDownloadService extends DownloadService {
  _StubDownloadService({List<DownloadedTrack>? seed})
      : _seed = List.of(seed ?? const []),
        super(
          catalog: CatalogService(registry: FakeSourceRegistry(const {})),
          repository: DownloadsRepository(
            databaseProvider: () => throw UnimplementedError(),
          ),
          storage: FakeDownloadStorage(),
        );

  List<DownloadedTrack> _seed;

  /// 已删除的记录（断言删除路径）。
  final List<DownloadedTrack> deleted = [];

  @override
  bool get supported => true;

  @override
  bool get initialized => true;

  @override
  List<DownloadedTrack> get downloads => List.unmodifiable(_seed);

  @override
  DownloadedTrack? recordFor(String sourceKey, String songId) {
    for (final song in _seed) {
      if (song.originSourceKey == sourceKey && song.originSongId == songId) {
        return song;
      }
    }
    return null;
  }

  @override
  DownloadedTrack? recordForTrack(Track track) =>
      recordFor(track.id.sourceKey, track.id.id);

  @override
  Future<void> delete(DownloadedTrack record) async {
    deleted.add(record);
    _seed = [for (final song in _seed) if (song.key != record.key) song];
    notifyListeners();
  }
}

/// 无封面缓存桩：封面占用在收藏页用例里恒为零（manager 不可用即零）。
class _NoopArtworkCache extends ArtworkCache {
  _NoopArtworkCache()
      : super(cacheService: CacheService(storage: MemoryCacheStorage()));
}

/// 假缓存存储：音频缓存索引（缓存 = 已下载识别）与单曲清缓存记录。
class _FakeCacheStorage implements CacheStorage {
  _FakeCacheStorage({Map<String, int>? files}) : files = files ?? {};

  /// 音频缓存文件名 → 字节数。
  final Map<String, int> files;

  /// 单曲清缓存的前缀调用（`AudioCacheStore.keyPrefix`）。
  final List<String> clearedPrefixes = [];

  @override
  Future<String?> audioCacheDir() async => '/cache/audio';

  @override
  Future<String?> artworkCacheDir() async => null;

  @override
  Future<int?> totalSpaceBytes() async => null;

  @override
  Future<CacheUsage> usage(String dirPath) async => CacheUsage.zero;

  @override
  Future<Map<String, int>> listFiles(String dirPath) async => Map.of(files);

  @override
  Future<int> deleteWhere(
    String dirPath, {
    required bool Function(String fileName) test,
  }) async {
    var deleted = 0;
    files.removeWhere((name, size) {
      if (!test(name)) return false;
      deleted++;
      return true;
    });
    return deleted;
  }

  @override
  Future<CacheDeleteResult> deleteMatching(
    String dirPath, {
    required String prefix,
    Duration protectAge = Duration.zero,
  }) async {
    clearedPrefixes.add(prefix);
    var bytes = 0;
    var count = 0;
    files.removeWhere((name, size) {
      if (!name.startsWith(prefix)) return false;
      bytes += size;
      count++;
      return true;
    });
    return CacheDeleteResult(
      deleted: CacheUsage(bytes: bytes, count: count),
    );
  }

  @override
  Future<void> clear(String dirPath) async => files.clear();

  @override
  Future<int> enforceAudioLimit(
    String dirPath, {
    required int maxBytes,
    required Duration protectAge,
  }) async =>
      0;

  @override
  Future<int> sweepArtwork(
    String dirPath, {
    required int maxObjects,
    required int staleDays,
  }) async =>
      0;
}

/// 本地歌曲记录：`imported` 决定删除语义（就地引用 / 下载副本）。
DownloadedTrack _localSong(
  String id, {
  String? title,
  String artist = '歌手',
  bool imported = false,
  int? durationMs = 180000,
}) =>
    DownloadedTrack(
      originSourceKey: imported ? kLocalSourceKey : 'kw',
      originSongId: id,
      title: title ?? '本地 $id',
      artist: artist,
      durationMs: durationMs,
      filePath: '/downloads/$id.mp3',
      downloadedAt: 1,
      imported: imported,
    );

/// 「收藏」页 widget 测试。
///
/// 覆盖：快捷播放（两次点击）、搜索按钮展开/收起、排序菜单、行尾 ♥、
/// 左滑单曲管理（移除/删除记录）、长按多选批量操作、合集弹层
/// （切换/新建/重命名/删除/拖拽排序）与常显滚动条。
///
/// 使用 [FakeLibraryRepository]（内存实现）：widget 测试处于 fake-async 区，
/// 真实数据库 I/O 不会完成（导致加载动画永不停止）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLibraryRepository repository;
  late FakePlaybackBackend backend;
  late PlaybackProvider playback;
  late LibraryProvider provider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repository = FakeLibraryRepository();
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(
      backend: backend,
      libraryRepository: repository,
    );
    provider = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
  });

  tearDown(() async {
    provider.dispose();
    playback.dispose();
    await repository.dispose();
  });

  Future<void> pumpFavorites(
    WidgetTester tester, {
    math.Random? shuffleRandom,
    DownloadService? downloads,
    CacheService? cache,
    Size size = const Size(1200, 2400),
    ShellReselectSignal? reselect,
    TextScaler? textScaler,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          ChangeNotifierProvider<LibraryProvider>.value(value: provider),
          if (downloads != null)
            ChangeNotifierProvider<DownloadService>.value(value: downloads),
          if (cache != null) ...[
            Provider<CacheService>.value(value: cache),
            Provider<TrackLocalDataService>.value(
              value: TrackLocalDataService(
                cacheService: cache,
                artworkCache: _NoopArtworkCache(),
                catalogService:
                    CatalogService(registry: FakeSourceRegistry(const {})),
                downloadService: downloads,
              ),
            ),
          ],
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Builder(
            builder: (context) {
              final Widget page = Scaffold(
                body: FavoritesPage(
                  shuffleRandom: shuffleRandom,
                  reselect: reselect,
                ),
              );
              if (textScaler == null) return page;
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                child: page,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 把 3 首曲目收藏进默认收藏列表（内部名 `__favorites__`）。
  Future<void> seedFavorites(WidgetTester tester) async {
    for (final title in ['Song B', 'Song A', 'Song C']) {
      await provider.toggleFavorite(
        sourceKey: 'wy',
        songId: title,
        title: title,
        artist: 'Artist $title',
        raw: {'songId': title},
      );
    }
  }

  Future<void> importLove(WidgetTester tester) async {
    await provider.importLxmcBytes(_lxmcBytes([
      _track(1),
      _track(2),
      _track(3),
    ]));
  }

  List<String> headlines(WidgetTester tester) => tester
      .widgetList<TrackRow>(find.byType(TrackRow))
      .map((row) => row.title)
      .toList();

  /// 变更流触发的后台重载在 widget 测试的 fake-async 区之外完成：
  /// 用 runAsync 让真实事件循环跑一次，再回到测试区重建 UI。
  Future<void> flushLibraryReloads(WidgetTester tester) async {
    await tester.runAsync(() async {
      await provider.pendingReload;
    });
    await tester.pumpAndSettle();
  }

  /// 打开合集弹层（点标题行的下拉箭头）。
  Future<void> openCollectionPicker(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.expand_more_rounded));
    await tester.pumpAndSettle();
  }

  /// 弹层内的合集行（限定在弹层 surface 内，避免与页面曲目行混淆）。
  Finder pickerRow(String name) => find.descendant(
        of: find.byType(M3EBottomSheetSurface),
        matching: find.byWidgetPredicate(
          (widget) => widget is M3EListItem && widget.headline == name,
        ),
      );

  /// 弹层标题行的工具动作（新建 `Icons.add_rounded` / 导入
  /// `Icons.library_add_rounded`）。
  ///
  /// 不按 key 定位：这两个动作按 docs/architecture.md §6 的口径要收成
  /// icon-only 动作组（组内动作没有 key，且组会额外构建一份不可见的测量副本），
  /// 故按图标 + `hitTestable()` 过滤出真实按钮（同 ai_dj_page_test /
  /// any_listen_page_test）；同一 finder 对当前的标准图标键实现也成立，
  /// 且断言的是「图标真的渲染出来」，依赖升级后无需再改。
  Finder pickerAction(IconData icon) => find
      .descendant(
        of: find.byType(M3EBottomSheetSurface),
        matching: find.byIcon(icon),
      )
      .hitTestable();

  /// 弹层内合集行的显示顺序（合集行；新建 / 导入是标题行按钮）。
  List<String> pickerHeadlines(WidgetTester tester) => tester
      .widgetList<M3EListItem>(
        find.descendant(
          of: find.byType(M3EBottomSheetSurface),
          matching: find.byType(M3EListItem),
        ),
      )
      .map((item) => item.headline)
      .toList();

  /// 打开弹层并选择指定合集。
  Future<void> selectCollection(WidgetTester tester, String name) async {
    await openCollectionPicker(tester);
    await tester.tap(pickerRow(name));
    await tester.pumpAndSettle();
  }

  /// 展开搜索栏（日常不占用行高）。
  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle();
  }

  testWidgets('空态：无任何合集时显示爱心图标与收藏空提示', (tester) async {
    await pumpFavorites(tester);

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('还没有收藏记录'), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    // 随机关闭；播放/暂停只在顶栏；搜索按钮在；
    // 搜索栏/数量行不常驻；导入入口在合集弹层。
    final shuffleButton = tester.widget<M3EIconButton>(
      find.widgetWithIcon(M3EIconButton, Icons.shuffle_rounded),
    );
    expect(shuffleButton.onPressed, isNull);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    expect(find.byType(AppSearchBar), findsNothing);
    expect(find.text('0 首'), findsNothing);
    expect(find.text('导入收藏'), findsNothing);
  });

  testWidgets('默认合集回退：仅有导入列表时点随机播放即可播放', (tester) async {
    await importLove(tester);
    // 随机起点用种子注入：期望值与页面内同一个种子序列一致。
    final expectedShuffleStart = math.Random(7).nextInt(3);
    await pumpFavorites(tester, shuffleRandom: math.Random(7));

    // 默认选中非空的 love（标题即切换器）。
    expect(find.text('love'), findsOneWidget);

    // 随机播放：整表洗牌 + 随机起点。
    await tester.tap(find.byIcon(Icons.shuffle_rounded));
    await tester.pumpAndSettle();

    final request = backend.lastRequest;
    expect(request, isNotNull);
    expect(request!.tracks, hasLength(3));
    expect(request.context?.name, 'love');
    expect(request.startIndex, expectedShuffleStart);
    expect(playback.currentMode, PlayMode.shuffle);
  });

  testWidgets('收藏列表：搜索展开收起 / 排序菜单 / 点击播放 / 行尾时长', (tester) async {
    await seedFavorites(tester);
    await pumpFavorites(tester);

    // 收藏非空时默认落在「我的收藏」。
    expect(headlines(tester), ['Song B', 'Song A', 'Song C']);
    // 行尾无爱心按钮。
    expect(find.byIcon(Icons.favorite_border_rounded), findsNothing);
    expect(find.byIcon(Icons.favorite_rounded), findsNothing);

    // 点击第 3 行从该位置播放，上下文为收藏名。
    await tester.tap(find.text('Song C'));
    await tester.pumpAndSettle();
    expect(backend.lastRequest!.startIndex, 2);
    expect(backend.lastRequest!.context?.name, '我的收藏');

    // 搜索按钮展开搜索栏，仅此时输入框占位。
    await openSearch(tester);
    expect(find.byType(AppSearchBar), findsOneWidget);
    await tester.enterText(find.byType(AppSearchBar), 'Artist Song A');
    await tester.pumpAndSettle();
    expect(headlines(tester), ['Song A']);

    // 退出搜索：过滤清空、输入框收起。
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(AppSearchBar), findsNothing);
    expect(headlines(tester), ['Song B', 'Song A', 'Song C']);

    // 排序入口在搜索行 ⋮ 菜单；可见顺序即播放队列顺序。
    await openSearch(tester);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按标题'));
    await tester.pumpAndSettle();
    expect(headlines(tester), ['Song A', 'Song B', 'Song C']);
  });

  testWidgets('标题行与搜索行高度一致：展开搜索头部不跳高', (tester) async {
    await seedFavorites(tester);
    await pumpFavorites(tester);

    final container = find.byType(ResponsivePageContainer);
    double headerHeight() => tester
        .getSize(
          find.descendant(of: container, matching: find.byType(Padding)).first,
        )
        .height;

    final idleHeight = headerHeight();
    await openSearch(tester);
    final searchHeight = headerHeight();
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    final restoredHeight = headerHeight();

    expect(searchHeight, idleHeight, reason: '展开搜索前后头部高度一致');
    expect(restoredHeight, idleHeight, reason: '收起搜索后头部高度不跳变');
  });

  testWidgets('标题行与多选栏高度一致：进入/退出多选头部不跳高', (tester) async {
    await seedFavorites(tester);
    await pumpFavorites(tester);

    final container = find.byType(ResponsivePageContainer);
    double headerHeight() => tester
        .getSize(
          find.descendant(of: container, matching: find.byType(Padding)).first,
        )
        .height;

    final idleHeight = headerHeight();
    await tester.longPress(find.text('Song A'));
    await tester.pumpAndSettle();
    final selectingHeight = headerHeight();
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    final restoredHeight = headerHeight();

    expect(selectingHeight, idleHeight, reason: '进入多选前后头部高度一致');
    expect(restoredHeight, idleHeight, reason: '退出多选后头部高度不跳变');
  });

  testWidgets('曲目行尾显示歌曲时长', (tester) async {
    await importLove(tester);
    await pumpFavorites(tester);

    // lxmc 的 interval（03:00）解码为 durationMs，行尾显示 m:ss。
    expect(find.text('3:00'), findsNWidgets(3));
    expect(find.byIcon(Icons.favorite_border_rounded), findsNothing);
  });

  testWidgets('我的收藏：长按多选批量取消收藏', (tester) async {
    await seedFavorites(tester);
    await pumpFavorites(tester);

    await tester.longPress(find.text('Song A'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);

    await tester.tap(find.text('Song B'));
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.heart_broken_rounded));
    await tester.pumpAndSettle();
    await flushLibraryReloads(tester);

    expect(await repository.favoriteKeys(), hasLength(1));
    expect(headlines(tester), ['Song C']);
  });

  testWidgets('合集切换：收藏与导入列表互不干扰', (tester) async {
    await seedFavorites(tester);
    await importLove(tester);
    await pumpFavorites(tester);

    // 收藏非空 → 默认收藏；love 需要弹层切换。
    expect(headlines(tester), ['Song B', 'Song A', 'Song C']);

    await selectCollection(tester, 'love');
    expect(find.text('love'), findsOneWidget);
    expect(headlines(tester), ['Song 1', 'Song 2', 'Song 3']);

    await tester.tap(find.byIcon(Icons.shuffle_rounded));
    await tester.pumpAndSettle();
    expect(backend.lastRequest!.context?.name, 'love');
    expect(backend.lastRequest!.tracks, hasLength(3));
  });

  testWidgets('桌面宽屏：合集切换入口只有标题行弹层', (tester) async {
    await seedFavorites(tester);
    await importLove(tester);
    await pumpFavorites(tester);

    // 标题行即切换器：下拉箭头恒在，标题显示当前合集名。
    expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);
    expect(find.text('我的收藏'), findsOneWidget);
    expect(headlines(tester), ['Song B', 'Song A', 'Song C']);

    // 弹层条目与标题行同一份解析顺序，当前合集走 M3E 列表选中态。
    await openCollectionPicker(tester);
    expect(pickerHeadlines(tester), ['我的收藏', '播放历史', 'love']);
    M3EListItem pickerItem(String name) =>
        tester.widget<M3EListItem>(pickerRow(name));
    expect(pickerItem('我的收藏').selected, isTrue);
    expect(pickerItem('love').selected, isFalse);

    await tester.tap(pickerRow('love'));
    await tester.pumpAndSettle();

    expect(headlines(tester), ['Song 1', 'Song 2', 'Song 3']);
    expect(find.text('love'), findsOneWidget, reason: '标题行跟随切换');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('窄屏 / 非桌面平台：同样只走标题行弹层切换', (tester) async {
    await seedFavorites(tester);
    await importLove(tester);

    // 桌面平台但窗口窄：入口不变。
    await pumpFavorites(tester, size: const Size(899, 1200));
    expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);
    await selectCollection(tester, 'love');
    expect(headlines(tester), ['Song 1', 'Song 2', 'Song 3']);

    // 非桌面平台 + 宽窗口：同一入口（平台覆盖由 variant 复位）。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpFavorites(tester);
    expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);
    await selectCollection(tester, '我的收藏');
    expect(headlines(tester), ['Song B', 'Song A', 'Song C']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('桌面宽屏：曲目列表渲染表格表头 + 三列，列左缘与表头对齐', (tester) async {
    await importLove(tester);
    await pumpFavorites(tester);

    // 表头（艺术家 / 专辑 / 时长）只在内容宽（窗口宽 − 栏宽）够时出现；
    // 收藏没有「播放时间」列（只有播放历史有）。
    expect(find.byType(TrackTableHeader), findsOneWidget);
    expect(find.text('艺术家'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('时长'), findsOneWidget);
    expect(find.text('播放时间'), findsNothing);
    final header =
        tester.widget<TrackTableHeader>(find.byType(TrackTableHeader));
    expect(header.spec, same(TrackRowColumnSpec.standard));
    expect(
      tester.getSize(find.byType(TrackTableHeader)).height,
      TrackTableHeader.extentOf(tester.element(find.byType(TrackTableHeader))),
      reason: '钉住表头（发现页）预声明的 extent 与实际高度一致',
    );

    // 行高走表格档（单行 56 = M3E 列表 token），列表 itemExtent 同一档。
    final rowFinder = find.byType(TrackRow).first;
    final rowContext = tester.element(rowFinder);
    final extent = TrackRow.extentOf(rowContext, tableColumns: true);
    expect(extent, M3ETheme.of(rowContext).listTheme.item.minHeight);
    expect(tester.getSize(rowFinder).height, extent);
    expect(
      tester.widget<ListView>(find.byType(ListView)).itemExtent,
      extent + TrackRow.gapOf(rowContext),
      reason: 'itemExtent 与行渲染同档（表格 56，不是单列的 72）',
    );

    // 行内列与表头同一份规范（同一实例，不是等值副本）。
    expect(
      tester.widget<TrackRow>(rowFinder).columns!.spec,
      same(header.spec),
      reason: '表头与行必须同 spec 来源',
    );

    // 行内三列：lxmc 曲目为 Artist N / Album N / 3:00（时长不再占行尾）。
    expect(find.text('Artist 1'), findsOneWidget);
    expect(find.text('Album 1'), findsOneWidget);
    expect(find.text('3:00'), findsNWidgets(3));

    // 表头存在的意义就是与列对齐：三列左缘必须逐列相同。
    expect(
      tester.getTopLeft(find.text('Artist 1')).dx,
      tester.getTopLeft(find.text('艺术家')).dx,
    );
    expect(
      tester.getTopLeft(find.text('Album 1')).dx,
      tester.getTopLeft(find.text('专辑')).dx,
    );
    expect(
      tester.getTopLeft(find.text('3:00').first).dx,
      tester.getTopLeft(find.text('时长')).dx,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('桌面宽屏：播放历史多一列「播放时间」，表头与行同 spec', (tester) async {
    await repository.addHistoryEntry(_history('1', playedAt: 2));
    await pumpFavorites(tester);
    await selectCollection(tester, '播放历史');

    expect(find.byType(TrackTableHeader), findsOneWidget);
    expect(find.text('播放时间'), findsOneWidget, reason: '历史独有列');
    expect(find.text('Album'), findsOneWidget);
    expect(find.text('3:00'), findsOneWidget);
    final header =
        tester.widget<TrackTableHeader>(find.byType(TrackTableHeader));
    expect(header.spec, same(TrackRowColumnSpec.history));
    expect(
      tester.widget<TrackRow>(find.byType(TrackRow).first).columns!.spec,
      same(header.spec),
      reason: '行与表头同一份列规范（历史档）',
    );
    // 行内播放时间 = 时间戳的紧凑文案（与同步日志同一格式）。
    expect(find.text(syncTimeText(2)), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Artist 1')).dx,
      tester.getTopLeft(find.text('艺术家')).dx,
    );
    expect(
      tester.getTopLeft(find.text('Album')).dx,
      tester.getTopLeft(find.text('专辑')).dx,
    );
    expect(
      tester.getTopLeft(find.text(syncTimeText(2))).dx,
      tester.getTopLeft(find.text('播放时间')).dx,
    );
    expect(
      tester.getTopLeft(find.text('3:00')).dx,
      tester.getTopLeft(find.text('时长')).dx,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('桌面宽屏：本地歌曲列表同样渲染表格列（缓存行带行尾标签仍对齐）', (tester) async {
    await repository.addHistoryEntry(_history('1', playedAt: 2));
    final cacheStorage = _FakeCacheStorage(files: {
      AudioCacheStore.key(sourceKey: 'wy', songId: '1', quality: '320k'):
          2048,
    });
    final cache = CacheService(storage: cacheStorage);
    await pumpFavorites(
      tester,
      downloads: _StubDownloadService(seed: [_localSong('2')]),
      cache: cache,
    );
    await selectCollection(tester, '本地歌曲');
    await tester.pump();

    expect(find.byType(TrackTableHeader), findsOneWidget);
    expect(find.text('缓存'), findsOneWidget, reason: '缓存行走行尾标签');
    expect(find.text('播放时间'), findsNothing, reason: '本地歌曲没有播放时间列');
    // 带标签的缓存行与普通行的列左缘一致（行尾固定槽宽）。
    final cachedRow = tester.getTopLeft(find.text('Artist 1')).dx;
    final downloadRow = tester.getTopLeft(find.text('歌手')).dx;
    expect(cachedRow, downloadRow, reason: '行尾标签不挤动列左缘');
    expect(cachedRow, tester.getTopLeft(find.text('艺术家')).dx);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('桌面宽屏大字号：缓存标签单行省略，不溢出固定槽', (tester) async {
    await repository.addHistoryEntry(_history('1', playedAt: 2));
    final cacheStorage = _FakeCacheStorage(files: {
      AudioCacheStore.key(sourceKey: 'wy', songId: '1', quality: '320k'):
          2048,
    });
    await pumpFavorites(
      tester,
      downloads: _StubDownloadService(seed: [_localSong('2')]),
      cache: CacheService(storage: cacheStorage),
      textScaler: const TextScaler.linear(3),
    );
    await selectCollection(tester, '本地歌曲');
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '大字号不溢出');
    final tag = tester.widget<Text>(find.text('缓存'));
    expect(tag.maxLines, 1);
    expect(tag.softWrap, isFalse);
    expect(tag.overflow, TextOverflow.ellipsis);
    // 单行渲染（不撑破表格档行高 56）；宽度被 56dp 固定槽约束。
    expect(
      tester.getSize(find.text('缓存')).height,
      lessThan(
        TrackRow.extentOf(
          tester.element(find.byType(TrackRow).first),
          tableColumns: true,
        ),
      ),
      reason: '标签单行渲染',
    );
    expect(
      tester.getSize(find.text('缓存')).width,
      lessThanOrEqualTo(TrackRowColumns.trailingSlotWidth),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('桌面窗口：表格判定按「窗口宽 − 栏宽」（719 单列 / 720 表格）',
      (tester) async {
    await importLove(tester);

    // 815 − 96（导航轨折叠宽）= 719 < 720：单列（时长仍在行尾）。
    await pumpFavorites(tester, size: const Size(815, 2400));
    expect(find.byType(TrackTableHeader), findsNothing);
    expect(find.text('专辑'), findsNothing);
    expect(find.text('Album 1'), findsNothing);
    expect(find.text('Artist 1'), findsOneWidget, reason: '副标题仍是歌手');
    expect(find.text('3:00'), findsNWidgets(3), reason: '时长仍在行尾');

    // 816 − 96 = 720：进表格档（页内没有常驻栏二次扣减）。
    await pumpFavorites(tester, size: const Size(816, 2400));
    expect(find.byType(TrackTableHeader), findsOneWidget);
    expect(find.text('Album 1'), findsOneWidget, reason: '行内展示专辑列');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('非桌面平台：宽窗口也不渲染表头（行保持单列）', (tester) async {
    // 测试环境默认平台为 android：窗口够宽也不进表格模式。
    await importLove(tester);
    await pumpFavorites(tester);

    expect(find.byType(TrackTableHeader), findsNothing);
    expect(find.text('专辑'), findsNothing);
    expect(find.text('Album 1'), findsNothing);
    expect(find.text('Artist 1'), findsOneWidget);
    expect(find.text('3:00'), findsNWidgets(3));
  });

  // 桌面多选：Ctrl 点选切换、Shift 区间选择、Esc 退出。修饰键经真实按键
  // 状态（HardwareKeyboard）注入，行点击时读取；移动端不注入这些回调。
  testWidgets('桌面多选：Ctrl 点击两行 = 两行选中，不触发播放',
      (tester) async {
    await seedFavorites(tester);
    await pumpFavorites(tester);

    bool selectedOf(String title) => tester
        .widget<TrackRow>(find.ancestor(
          of: find.text(title),
          matching: find.byType(TrackRow),
        ))
        .selected;

    // Ctrl 按住点第一行：进入选择模式（等价长按）并选中该行。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('Song B'));
    await tester.pumpAndSettle();
    expect(selectedOf('Song B'), isTrue);
    expect(selectedOf('Song A'), isFalse);

    // 再 Ctrl 点第二行：追加选中（切换语义），两行都保持选中。
    await tester.tap(find.text('Song A'));
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(selectedOf('Song B'), isTrue);
    expect(selectedOf('Song A'), isTrue);
    expect(selectedOf('Song C'), isFalse);
    expect(find.text('2'), findsOneWidget, reason: '选择栏计数 = 2');
    expect(backend.lastRequest, isNull, reason: '修饰键点击不播放');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('桌面多选：Shift 点击 = 锚点到当前行的区间选中', (tester) async {
    await seedFavorites(tester);
    // 第四首：让区间是「部分区间」而不是整表。
    await provider.toggleFavorite(
      sourceKey: 'wy',
      songId: 'Song D',
      title: 'Song D',
      artist: 'Artist Song D',
      raw: {'songId': 'Song D'},
    );
    await pumpFavorites(tester);

    bool selectedOf(String title) => tester
        .widget<TrackRow>(find.ancestor(
          of: find.text(title),
          matching: find.byType(TrackRow),
        ))
        .selected;

    // 普通点击第 2 行（Song A）落锚点，同时照常点播。
    await tester.tap(find.text('Song A'));
    await tester.pumpAndSettle();
    expect(backend.lastRequest!.startIndex, 1, reason: '普通点击仍是点播语义');

    // Shift 点第 4 行（Song D）：选中 Song A 到 Song D 的可见区间。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('Song D'));
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(selectedOf('Song B'), isFalse, reason: '区间外的行不选中');
    expect(selectedOf('Song A'), isTrue);
    expect(selectedOf('Song C'), isTrue);
    expect(selectedOf('Song D'), isTrue);
    expect(find.text('3'), findsOneWidget, reason: '选择栏计数 = 3');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('桌面多选：Esc 退出选择模式（未在选择模式时无副作用）',
      (tester) async {
    await seedFavorites(tester);
    await pumpFavorites(tester);

    // 未在选择模式：Esc 不产生任何变化（放行给其它 Esc 作用域）。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('1'), findsNothing);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);

    // 长按进入选择模式 → Esc 退出。
    await tester.longPress(find.text('Song A'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget, reason: '长按选中该行');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('1'), findsNothing, reason: '选择栏已收起');
    expect(
      find.byIcon(Icons.search_rounded),
      findsOneWidget,
      reason: '回到常规标题行',
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('合集弹层：当前合集走 M3E selected 态，数量走 trailingText', (tester) async {
    await seedFavorites(tester);
    await importLove(tester);
    await pumpFavorites(tester);

    await openCollectionPicker(tester);

    // 标题行两个小按钮：新建 / 导入。
    expect(pickerAction(Icons.add_rounded), findsOneWidget);
    expect(pickerAction(Icons.library_add_rounded), findsOneWidget);

    final current = tester.widget<M3EListItem>(pickerRow('我的收藏'));
    expect(current.selected, isTrue, reason: '当前合集用 M3E 选中态');
    expect(current.trailingText, '3 首', reason: '数量走 M3E 元文本槽');

    final other = tester.widget<M3EListItem>(pickerRow('love'));
    expect(other.selected, isFalse);
    expect(other.trailingText, '3 首');
  });

  testWidgets('合集弹层：窄屏（手机宽度）不溢出，行内容齐全', (tester) async {
    await seedFavorites(tester);
    await importLove(tester);
    await provider.createPlaylist('一个特别长的列表名称用来验证省略号与布局稳定性');
    await pumpFavorites(
      tester,
      downloads: _StubDownloadService(seed: [_localSong('1')]),
      size: const Size(360, 780),
    );

    await openCollectionPicker(tester);

    expect(tester.takeException(), isNull);
    for (final name in [
      '我的收藏',
      '播放历史',
      '本地歌曲',
      '一个特别长的列表名称用来验证省略号与布局稳定性',
      'love',
    ]) {
      expect(pickerRow(name), findsOneWidget, reason: name);
    }
    expect(pickerAction(Icons.add_rounded), findsOneWidget);
    expect(pickerAction(Icons.library_add_rounded), findsOneWidget);
  });

  testWidgets('合集弹层：拖动把手自定义顺序并持久化', (tester) async {
    await seedFavorites(tester);
    await importLove(tester);
    await pumpFavorites(tester);

    await openCollectionPicker(tester);
    expect(
      pickerHeadlines(tester),
      ['我的收藏', '播放历史', 'love'],
    );

    // 把 love 的把手向上拖到「播放历史」之前。必须小步移动：
    // 单步位移过大时 ReorderableListView 的目标索引计算会跳过（实测）。
    final handle = find.byIcon(Icons.drag_handle_rounded).last;
    final start = tester.getCenter(handle);
    final rowDelta = tester.getCenter(pickerRow('播放历史')).dy -
        tester.getCenter(pickerRow('love')).dy;
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 50));
    for (var step = 0; step < 4; step++) {
      await gesture.moveBy(Offset(0, rowDelta / 4));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      pickerHeadlines(tester),
      ['我的收藏', 'love', '播放历史'],
    );

    final loveId =
        provider.playlists.firstWhere((playlist) => playlist.name == 'love').id;
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getStringList('favorites_collection_order'),
      ['favorites', 'playlist:$loveId', 'history'],
    );
  });

  testWidgets('合集弹层：新建列表并切换过去', (tester) async {
    await seedFavorites(tester);
    await pumpFavorites(tester);

    await openCollectionPicker(tester);
    await tester.tap(pickerAction(Icons.add_rounded));
    await tester.pumpAndSettle();

    // 命名对话框：输入名称并创建。
    await tester.enterText(find.byType(M3ETextField), '路上听');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    await flushLibraryReloads(tester);

    expect(find.text('路上听'), findsOneWidget);
    expect(find.text('这个列表还没有曲目'), findsOneWidget);
    expect(await repository.findPlaylistByName('路上听'), isNotNull);
  });

  testWidgets('合集弹层：重命名自建列表', (tester) async {
    await importLove(tester);
    await pumpFavorites(tester);

    await openCollectionPicker(tester);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名列表'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(M3ETextField), '跑步');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(pickerRow('跑步'), findsOneWidget);
    await flushLibraryReloads(tester);
    expect(await repository.findPlaylistByName('跑步'), isNotNull);
  });

  testWidgets('合集弹层：删除自建列表（确认弹窗）', (tester) async {
    await importLove(tester);
    await pumpFavorites(tester);

    await openCollectionPicker(tester);
    expect(
      pickerHeadlines(tester),
      ['我的收藏', '播放历史', 'love'],
    );

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除列表'));
    await tester.pumpAndSettle();
    // 确认弹窗（M3EButton 文案为「删除」）。
    await tester.tap(find.widgetWithText(M3EButton, '删除'));
    await tester.pumpAndSettle();

    // 弹层行局部移除；仓库同步删除。
    expect(
      pickerHeadlines(tester),
      ['我的收藏', '播放历史'],
    );
    await flushLibraryReloads(tester);
    expect(await repository.listPlaylists(), isEmpty);

    // 关闭弹层后页面回退到空的「我的收藏」。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('还没有收藏记录'), findsOneWidget);
    expect(find.text('我的收藏'), findsOneWidget);
  });

  testWidgets('自建列表：左滑从列表移除', (tester) async {
    await importLove(tester);
    await pumpFavorites(tester);
    expect(headlines(tester), ['Song 1', 'Song 2', 'Song 3']);

    await tester.drag(find.text('Song 2'), const Offset(-260, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.playlist_remove_rounded));
    await tester.pumpAndSettle();
    await flushLibraryReloads(tester);

    expect(headlines(tester), ['Song 1', 'Song 3']);
    final loveId =
        provider.playlists.firstWhere((playlist) => playlist.name == 'love').id;
    expect(await repository.listPlaylistTracks(loveId), hasLength(2));
  });

  testWidgets('我的收藏：左滑「加入列表」复制到自建列表', (tester) async {
    await seedFavorites(tester);
    await importLove(tester);
    await pumpFavorites(tester);

    await tester.drag(find.text('Song A'), const Offset(-260, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.playlist_add_rounded));
    await tester.pumpAndSettle();

    // 弹层选择 love → 复制并提示。
    await tester.tap(find.text('love'));
    await tester.pumpAndSettle();
    await flushLibraryReloads(tester);

    final loveId =
        provider.playlists.firstWhere((playlist) => playlist.name == 'love').id;
    final copied = await repository.listPlaylistTracks(loveId);
    expect(copied.map((track) => track.songId), contains('Song A'));
    expect(find.text('已加入「love」'), findsOneWidget);
  });

  testWidgets('左滑动作：M3E 胶囊按钮（tonal + filled）与动作名 tooltip', (tester) async {
    await seedFavorites(tester);
    await pumpFavorites(tester);

    await tester.drag(find.text('Song B'), const Offset(-260, 0));
    await tester.pumpAndSettle();

    final buttons = tester
        .widgetList<M3EIconButton>(
          find.descendant(
            of: find.byType(SwipeRevealRow),
            matching: find.byType(M3EIconButton),
          ),
        )
        .toList();
    expect(buttons, hasLength(3));
    // 中性动作 tonal（加入列表 / 换源）、移除类 filled（错误色胶囊）。
    expect(buttons[0].variant, M3EIconButtonVariant.tonal);
    expect(buttons[1].variant, M3EIconButtonVariant.tonal);
    expect(buttons.last.variant, M3EIconButtonVariant.filled);
    // 纯图标语义有限：tooltip 承担动作名。
    expect(find.byTooltip('加入列表'), findsOneWidget);
    expect(find.byTooltip('换源'), findsOneWidget);
    expect(find.byTooltip('取消收藏'), findsOneWidget);

    // 完全露出后：行位移 = Σ 动作宽 + 间距；胶囊均分内宽（行高 − 8 高），三段等宽。
    final sizes = [
      for (final button in buttons) tester.getSize(find.byWidget(button)),
    ];
    expect(sizes.first.height, 64);
    expect(sizes.last.height, 64);
    expect(sizes[1].width, moreOrLessEquals(sizes.first.width, epsilon: 0.01));
    expect(sizes[2].width, moreOrLessEquals(sizes.first.width, epsilon: 0.01));
  });

  testWidgets('在自建列表收藏后不会跳回我的收藏（默认选择固定）', (tester) async {
    await importLove(tester);
    await pumpFavorites(tester);
    // 收藏为空 → 默认回退到 love；此时还不存在「我的收藏」列表。
    expect(find.text('love'), findsOneWidget);

    await tester.drag(find.text('Song 1'), const Offset(-260, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.playlist_add_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的收藏'));
    await tester.pumpAndSettle();
    await flushLibraryReloads(tester);

    // 仍停留在 love：首次收藏创建默认收藏后不自动跳转。
    expect(find.text('love'), findsOneWidget);
    expect(headlines(tester), ['Song 1', 'Song 2', 'Song 3']);
    expect(await repository.favoriteKeys(), contains('wy:1'));
  });

  testWidgets('合集弹层：导入收藏入口（文件导入选择）', (tester) async {
    await seedFavorites(tester);
    await pumpFavorites(tester);

    await openCollectionPicker(tester);
    await tester.tap(pickerAction(Icons.library_add_rounded));
    await tester.pumpAndSettle();

    // 测试环境无 DiscoverProvider → 仅文件导入选项；链接导入在生产环境可见。
    expect(find.text('从 .lxmc 文件导入'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  });

  testWidgets('合集弹层：五平台链接导入（注入 DiscoverProvider）', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final discover = DiscoverProvider(
      playbackProvider: playback,
      libraryProvider: provider,
      sources: {'wy': FakeDiscoverSource()},
    );
    addTearDown(discover.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          ChangeNotifierProvider<LibraryProvider>.value(value: provider),
          ChangeNotifierProvider<DiscoverProvider>.value(value: discover),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: const Scaffold(body: FavoritesPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await openCollectionPicker(tester);
    await tester.tap(pickerAction(Icons.library_add_rounded));
    await tester.pumpAndSettle();
    expect(find.text('从歌单链接导入'), findsOneWidget);
    await tester.tap(find.text('从歌单链接导入'));
    await tester.pumpAndSettle();

    // 空链接：停留并提示。
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('粘贴歌单链接或 ID'), findsWidgets);

    // 输入链接 → 拉取详情并导入，随后切换到导入的列表。
    await tester.enterText(find.byType(M3ETextField), 'abc');
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await flushLibraryReloads(tester);

    expect(find.text('已导入 1 首'), findsOneWidget);
    expect(find.text('歌单详情'), findsOneWidget);
    expect(find.text('歌曲A'), findsOneWidget);
  });

  testWidgets('自建列表：长按多选批量移除', (tester) async {
    await importLove(tester);
    await pumpFavorites(tester);

    await tester.longPress(find.text('Song 1'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);

    await tester.tap(find.text('Song 3'));
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.playlist_remove_rounded));
    await tester.pumpAndSettle();
    await flushLibraryReloads(tester);

    expect(headlines(tester), ['Song 2']);
  });

  testWidgets('自建列表：调整顺序模式长按拖动并持久化', (tester) async {
    await importLove(tester);
    await pumpFavorites(tester);

    // 入口在搜索行 ⋮ 菜单；进入后搜索行收起，显示拖动提示与把手。
    await openSearch(tester);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('调整顺序'));
    await tester.pumpAndSettle();

    expect(find.byType(AppSearchBar), findsNothing);
    expect(find.text('长按拖动调整顺序'), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle_rounded), findsNWidgets(3));

    // 长按 Song 3 拖到 Song 1 之前（向上两行）。
    final rowDelta = tester.getCenter(find.text('Song 2')).dy -
        tester.getCenter(find.text('Song 1')).dy;
    final gesture =
        await tester.startGesture(tester.getCenter(find.text('Song 3')));
    await tester.pump(const Duration(milliseconds: 700));
    for (var step = 0; step < 6; step++) {
      await gesture.moveBy(Offset(0, -rowDelta * 2 / 6));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    final loveId =
        provider.playlists.firstWhere((playlist) => playlist.name == 'love').id;
    expect(
      (await repository.listPlaylistTracks(loveId))
          .map((track) => track.songId)
          .toList(),
      ['3', '1', '2'],
    );

    // 完成退出排序模式，回到常规头部。
    await tester.tap(find.byIcon(Icons.done_rounded));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
  });

  testWidgets('播放历史：弹层进入历史合集，行点击播放、左滑加入我的收藏', (tester) async {
    await repository.addHistoryEntry(_history('1', playedAt: 2));
    await repository.addHistoryEntry(_history('2', playedAt: 1));
    await pumpFavorites(tester);

    // 播放历史不参与默认回退：需从弹层显式进入。
    await selectCollection(tester, '播放历史');

    expect(headlines(tester), ['Song 1', 'Song 2']);
    expect(find.text('3:00'), findsNWidgets(2));

    await tester.tap(find.text('Song 2'));
    await tester.pumpAndSettle();
    final request = backend.lastRequest;
    expect(request, isNotNull);
    expect(request!.tracks, hasLength(2));
    expect(request.startIndex, 1);
    expect(request.context?.name, '播放历史');

    // 左滑「加入列表 → 我的收藏」。
    await tester.drag(find.text('Song 2'), const Offset(-260, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.playlist_add_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的收藏'));
    await tester.pumpAndSettle();
    expect(await repository.favoriteKeys(), contains('wy:2'));
  });

  testWidgets('播放历史：左滑删除单条记录', (tester) async {
    await repository.addHistoryEntry(_history('1', playedAt: 2));
    await repository.addHistoryEntry(_history('2', playedAt: 1));
    await pumpFavorites(tester);
    await selectCollection(tester, '播放历史');

    await tester.drag(find.text('Song 2'), const Offset(-260, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_rounded));
    await tester.pumpAndSettle();
    await flushLibraryReloads(tester);

    expect(headlines(tester), ['Song 1']);
    expect(await repository.listHistory(), hasLength(1));
  });

  testWidgets('播放历史：长按多选批量删除', (tester) async {
    await repository.addHistoryEntry(_history('1', playedAt: 2));
    await repository.addHistoryEntry(_history('2', playedAt: 1));
    await pumpFavorites(tester);
    await selectCollection(tester, '播放历史');

    await tester.longPress(find.text('Song 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Song 2'));
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_rounded));
    await tester.pumpAndSettle();
    await flushLibraryReloads(tester);

    expect(find.text('还没有播放记录'), findsOneWidget);
    expect(await repository.listHistory(), isEmpty);
  });

  testWidgets('播放历史：搜索行菜单清空历史（确认弹窗）', (tester) async {
    await repository.addHistoryEntry(_history('1'));
    await pumpFavorites(tester);

    await selectCollection(tester, '播放历史');
    expect(find.text('Song 1'), findsOneWidget);

    await openSearch(tester);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空历史'));
    await tester.pumpAndSettle();

    // 确认弹窗：标题 + 取消 + 填充按钮同名，取填充按钮。
    await tester.tap(find.widgetWithText(M3EButton, '清空历史'));
    await tester.pumpAndSettle();

    expect(find.text('还没有播放记录'), findsOneWidget);
    expect(await repository.listHistory(), isEmpty);
  });

  testWidgets('曲目列表：常显可拖动滚动条', (tester) async {
    await seedFavorites(tester);
    await pumpFavorites(tester);

    final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
    expect(scrollbar.thumbVisibility, isTrue);
    expect(scrollbar.interactive, isTrue);
    expect(scrollbar.controller, isNotNull);
  });

  testWidgets('大列表：固定行高懒加载，只构建视口附近行，滚动条可手拖', (tester) async {
    for (var i = 0; i < 200; i++) {
      await provider.toggleFavorite(
        sourceKey: 'wy',
        songId: '$i',
        title: 'Song $i',
        artist: 'Artist $i',
        raw: {'songId': '$i'},
      );
    }
    await pumpFavorites(tester);

    // 懒加载：200 首只构建视口附近的行。
    final rows = tester.widgetList<TrackRow>(find.byType(TrackRow)).toList();
    expect(rows, isNotEmpty);
    expect(rows.length, lessThan(60), reason: '200 首只构建视口附近的行');

    // 固定行高：itemExtent 预取高度（行高 + 行距，滚动条拇指/拖动精确）。
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(
      list.itemExtent,
      TrackRow.extent +
          TrackRow.gapOf(tester.element(find.byType(TrackRow).first)),
    );

    // 标题/歌手都单行省略：固定高度不会被换行撑高。
    final firstRowTexts = tester
        .widgetList<Text>(find.descendant(
          of: find.byType(TrackRow).first,
          matching: find.byType(Text),
        ))
        .toList();
    expect(firstRowTexts, hasLength(2));
    expect(firstRowTexts.every((text) => text.maxLines == 1), isTrue);

    // 滚动条常显且可手拖：按住顶部拇指拖动后 offset 变化。
    final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
    expect(scrollbar.interactive, isTrue);
    final controller = scrollbar.controller!;
    final rect = tester.getRect(find.byType(Scrollbar));
    final gesture = await tester.startGesture(
      Offset(rect.right - 3, rect.top + 10),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    // 滚动节流落盘（500ms）已触发，避免测试结束挂起计时器。
    await tester.pump(const Duration(milliseconds: 600));
  });

  /// 收藏 [count] 首（滚动恢复/落盘用例需要足够长的列表）。
  Future<void> seedManyFavorites(WidgetTester tester, {int count = 200}) async {
    for (var i = 0; i < count; i++) {
      await provider.toggleFavorite(
        sourceKey: 'wy',
        songId: '$i',
        title: 'Song $i',
        artist: 'Artist $i',
        raw: {'songId': '$i'},
      );
    }
  }

  testWidgets('重启恢复：活跃合集为播放历史（预置持久化选择）', (tester) async {
    await repository.addHistoryEntry(_history('1', playedAt: 2));
    // 模拟上次退出时停留在播放历史。
    SharedPreferences.setMockInitialValues({
      'favorites_selected_collection': LibraryCollections.historySentinel,
    });
    await pumpFavorites(tester);

    expect(find.text('播放历史'), findsOneWidget);
    expect(find.text('Song 1'), findsOneWidget);
  });

  testWidgets('重启恢复：收藏列表滚动位置', (tester) async {
    await seedManyFavorites(tester);
    // 模拟上次退出时「我的收藏」滚动到 400。
    SharedPreferences.setMockInitialValues({
      'favorites_selected_collection': LibraryCollections.favoritesSentinel,
      'favorites_scroll_offsets': '{"favorites": 400.0}',
    });
    await pumpFavorites(tester);

    expect(find.text('我的收藏'), findsOneWidget);
    final controller =
        tester.widget<Scrollbar>(find.byType(Scrollbar)).controller!;
    expect(controller.offset, closeTo(400, 1));
    // 恢复触发的落盘节流计时器：推进到触发，避免挂起。
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('底栏重复点击（壳层请求）：当前合集回到列表顶部', (tester) async {
    final reselect = ShellReselectSignal();
    addTearDown(reselect.dispose);
    await seedManyFavorites(tester);
    await pumpFavorites(tester, reselect: reselect);

    final controller =
        tester.widget<Scrollbar>(find.byType(Scrollbar)).controller!;
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0), reason: '先滚离顶部');

    // 底栏重复点击「收藏」→ 当前合集的列表回到顶部。
    reselect.trigger();
    await tester.pumpAndSettle();
    expect(controller.offset, 0, reason: '壳层重复点击应回到顶部');

    // 滚动落盘节流计时器跑完，避免挂起。
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('滚动位置节流落盘（≥1 次写入）', (tester) async {
    await seedManyFavorites(tester);
    await pumpFavorites(tester);

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(LibraryCollections.scrollOffsetsKey);
    expect(raw, isNotNull);
    final saved = jsonDecode(raw!) as Map<String, dynamic>;
    expect(saved[LibraryCollections.favoritesOrderKey], greaterThan(0));
  });

  testWidgets('本地歌曲：弹层出现合集，进入后播放 / 搜索过滤', (tester) async {
    final service = _StubDownloadService(seed: [
      _localSong('1', title: '下载的歌'),
      _localSong('2', title: '导入的歌', imported: true),
    ]);
    await pumpFavorites(tester, downloads: service);

    await openCollectionPicker(tester);
    expect(pickerHeadlines(tester), ['我的收藏', '播放历史', '本地歌曲']);
    await tester.tap(pickerRow('本地歌曲'));
    await tester.pumpAndSettle();

    // 标题行即合集名；导入按钮只在本地歌曲合集显示。
    expect(find.text('本地歌曲'), findsOneWidget);
    expect(find.byKey(const Key('localSongsImportButton')), findsOneWidget);
    expect(headlines(tester), ['下载的歌', '导入的歌']);

    // 点行播放：可见顺序即队列，来源为本地曲目。
    await tester.tap(find.text('导入的歌'));
    await tester.pumpAndSettle();
    final request = backend.lastRequest;
    expect(request, isNotNull);
    expect(request!.startIndex, 1);
    expect(request.context?.name, '本地歌曲');
    expect(request.tracks.first.id.sourceKey, kLocalSourceKey);

    // 搜索过滤（同一语义：标题 / 歌手子串）。
    await openSearch(tester);
    await tester.enterText(find.byType(AppSearchBar), '导入');
    await tester.pumpAndSettle();
    expect(headlines(tester), ['导入的歌']);
  });

  testWidgets('本地歌曲：左滑删除按来源区分（下载删文件 / 导入只移出列表）', (tester) async {
    final service = _StubDownloadService(seed: [
      _localSong('1', title: '下载的歌'),
      _localSong('2', title: '导入的歌', imported: true),
    ]);
    await pumpFavorites(tester, downloads: service);
    await selectCollection(tester, '本地歌曲');

    // 导入项：确认文案是「从列表移除」。
    await tester.drag(find.text('导入的歌'), const Offset(-260, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_rounded));
    await tester.pumpAndSettle();
    expect(find.text('从列表移除'), findsWidgets);
    await tester.tap(find.widgetWithText(M3EButton, '删除'));
    await tester.pumpAndSettle();
    expect(service.deleted.map((song) => song.key), ['local:2']);
    expect(headlines(tester), ['下载的歌']);

    // 下载副本：确认文案是「删除下载」。
    await tester.drag(find.text('下载的歌'), const Offset(-260, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_rounded));
    await tester.pumpAndSettle();
    expect(find.text('删除下载'), findsWidgets);
    await tester.tap(find.widgetWithText(M3EButton, '删除'));
    await tester.pumpAndSettle();
    expect(service.deleted.map((song) => song.key), ['local:2', 'kw:1']);
    expect(find.text('还没有本地歌曲'), findsOneWidget);
  });

  testWidgets('本地歌曲：长按多选删除（混合来源文案）', (tester) async {
    final service = _StubDownloadService(seed: [
      _localSong('1', title: '下载的歌'),
      _localSong('2', title: '导入的歌', imported: true),
    ]);
    await pumpFavorites(tester, downloads: service);
    await selectCollection(tester, '本地歌曲');

    await tester.longPress(find.text('下载的歌'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入的歌'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_rounded));
    await tester.pumpAndSettle();
    expect(
      find.text('删除本地副本？音频、歌词与封面文件将一并删除；导入的本地歌曲只从列表移除。'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(M3EButton, '删除'));
    await tester.pumpAndSettle();
    expect(service.deleted.map((song) => song.key), ['kw:1', 'local:2']);
    expect(find.text('还没有本地歌曲'), findsOneWidget);
  });

  testWidgets('本地歌曲：未注入下载服务（能力不可用）时合集与入口隐藏', (tester) async {
    await pumpFavorites(tester);

    await openCollectionPicker(tester);
    expect(pickerHeadlines(tester), ['我的收藏', '播放历史']);
  });

  testWidgets('本地歌曲：空态显示导入入口', (tester) async {
    await pumpFavorites(tester, downloads: _StubDownloadService());
    await selectCollection(tester, '本地歌曲');

    expect(find.text('还没有本地歌曲'), findsOneWidget);
    expect(find.widgetWithText(M3EButton, '导入本地歌曲'), findsOneWidget);
  });

  testWidgets('本地歌曲：滚动位置独立持久化', (tester) async {
    final service = _StubDownloadService(seed: [
      for (var i = 0; i < 40; i++) _localSong('$i', title: '本地 ${i.toString().padLeft(2, '0')}'),
    ]);
    await pumpFavorites(tester, downloads: service);
    await selectCollection(tester, '本地歌曲');

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(LibraryCollections.scrollOffsetsKey);
    expect(raw, isNotNull);
    final saved = jsonDecode(raw!) as Map<String, dynamic>;
    expect(saved[LibraryCollections.downloadsOrderKey], greaterThan(0));
  });

  testWidgets('本地歌曲：缓存曲目入列（原曲身份）且删除 = 清缓存', (tester) async {
    await repository.addHistoryEntry(_history('1', playedAt: 2));
    final cacheStorage = _FakeCacheStorage(files: {
      AudioCacheStore.key(sourceKey: 'wy', songId: '1', quality: '320k'):
          2048,
    });
    final cache = CacheService(storage: cacheStorage);
    await pumpFavorites(tester, downloads: _StubDownloadService(), cache: cache);
    await selectCollection(tester, '本地歌曲');
    await tester.pump();

    expect(headlines(tester), ['Song 1']);
    expect(find.text('缓存'), findsOneWidget);

    // 播放保留原曲身份（不是 local 音源）：解析时命中缓存直接 file://。
    await tester.tap(find.text('Song 1'));
    await tester.pumpAndSettle();
    expect(backend.lastRequest!.tracks.single.id.sourceKey, 'wy');

    // 左滑删除：确认文案是「清除缓存」，动作只清缓存、不动下载记录。
    await tester.drag(find.text('Song 1'), const Offset(-260, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_rounded));
    await tester.pumpAndSettle();
    expect(find.text('清除缓存'), findsWidgets);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(cacheStorage.clearedPrefixes, [
      AudioCacheStore.keyPrefix(sourceKey: 'wy', songId: '1'),
    ]);
    // 缓存索引已清：列表随缓存 revision 刷新为空。
    expect(headlines(tester), isEmpty);
  });

  testWidgets('本地歌曲：已有下载记录的曲目不重复列缓存行', (tester) async {
    await repository.addHistoryEntry(_history('1', playedAt: 2));
    final downloads = _StubDownloadService(seed: [
      const DownloadedTrack(
        originSourceKey: 'wy',
        originSongId: '1',
        title: '下载的歌',
        filePath: '/downloads/1.mp3',
        downloadedAt: 1,
      ),
    ]);
    final cacheStorage = _FakeCacheStorage(files: {
      AudioCacheStore.key(sourceKey: 'wy', songId: '1', quality: '320k'):
          2048,
    });
    final cache = CacheService(storage: cacheStorage);
    await pumpFavorites(tester, downloads: downloads, cache: cache);
    await selectCollection(tester, '本地歌曲');
    await tester.pump();

    expect(headlines(tester), ['下载的歌']);
    expect(find.text('缓存'), findsNothing);
  });
}

Map<String, dynamic> _track(int id) => {
      'id': 'wy_$id',
      'name': 'Song $id',
      'singer': 'Artist $id',
      'source': 'wy',
      'interval': '03:00',
      'meta': {'songId': id, 'albumName': 'Album $id'},
    };

PlayHistoryEntry _history(String songId, {int playedAt = 1}) =>
    PlayHistoryEntry(
      sourceKey: 'wy',
      songId: songId,
      title: 'Song $songId',
      artist: 'Artist $songId',
      album: 'Album',
      durationMs: 180000,
      raw: {'songId': songId},
      playedAt: playedAt,
    );

/// 合成 .lxmc（gzip JSON），名称 `list__name_love` → 清洗为 `love`。
Uint8List _lxmcBytes(List<Map<String, dynamic>> list) {
  return Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode({
    'type': 'playListPart_v2',
    'data': {'id': 'x', 'name': 'list__name_love', 'list': list},
  }))));
}
