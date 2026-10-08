import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/pages/favorites.dart';
import 'package:molia/providers/discover_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:material_3_expressive/components/bottom_sheets/components/m3e_bottom_sheet_surface.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_discover_api.dart';
import 'support/fake_library_repository.dart';
import 'support/fakes.dart';

/// 「收藏」页 widget 测试（歌曲管理重设计版）。
///
/// 覆盖：快捷播放（两次点击）、搜索按钮展开/收起、排序菜单、行尾 ♥、
/// 左滑单曲管理（移除/删除记录）、长按多选批量操作、合集弹层
/// （切换/新建/重命名/删除/拖拽排序）与常显滚动条。
///
/// 使用 [FakeLibraryRepository]（内存实现）：widget 测试处于 fake-async 区，
/// 真实 sqflite I/O 不会完成（导致加载动画永不停止）。
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

  Future<void> pumpFavorites(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
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
      .widgetList<M3EListItem>(find.byType(M3EListItem))
      .map((item) => item.headline)
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

  /// 弹层内合集行的显示顺序（含「新建列表」行）。
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

    expect(find.text('还没有收藏记录'), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    // 播放/随机关闭；搜索按钮在；搜索栏/数量行不常驻；导入入口已移至合集弹层。
    final playButton = tester.widget<M3EIconButton>(
      find.widgetWithIcon(M3EIconButton, Icons.play_arrow_rounded),
    );
    final shuffleButton = tester.widget<M3EIconButton>(
      find.widgetWithIcon(M3EIconButton, Icons.shuffle_rounded),
    );
    expect(playButton.onPressed, isNull);
    expect(shuffleButton.onPressed, isNull);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    expect(find.byType(M3ETextField), findsNothing);
    expect(find.text('0 首'), findsNothing);
    expect(find.text('导入收藏夹'), findsNothing);
  });

  testWidgets('默认合集回退：仅有导入列表时两次点击即可播放（播放全部/随机）', (tester) async {
    await importLove(tester);
    await pumpFavorites(tester);

    // 默认选中非空的 love（标题即切换器）。
    expect(find.text('love'), findsOneWidget);

    // 第 1 击在导航切 tab（此处已挂载页面），第 2 击播放全部。
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pumpAndSettle();

    final request = backend.lastRequest;
    expect(request, isNotNull);
    expect(request!.tracks, hasLength(3));
    expect(request.startIndex, 0);
    expect(request.context?.name, 'love');
    expect(playback.currentMode, PlayMode.sequential);

    await tester.tap(find.byIcon(Icons.shuffle_rounded));
    await tester.pumpAndSettle();

    expect(playback.currentMode, PlayMode.shuffle);
    expect(backend.lastRequest!.tracks, hasLength(3));
    expect(backend.lastRequest!.startIndex, 0);
  });

  testWidgets('收藏列表：搜索展开收起 / 排序菜单 / 点击播放 / 行尾时长', (tester) async {
    await seedFavorites(tester);
    await pumpFavorites(tester);

    // 收藏非空时默认落在「我的收藏」。
    expect(headlines(tester), ['Song B', 'Song A', 'Song C']);
    // 行尾不再有爱心按钮。
    expect(find.byIcon(Icons.favorite_border_rounded), findsNothing);
    expect(find.byIcon(Icons.favorite_rounded), findsNothing);

    // 点击第 3 行从该位置播放，上下文为收藏名。
    await tester.tap(find.text('Song C'));
    await tester.pumpAndSettle();
    expect(backend.lastRequest!.startIndex, 2);
    expect(backend.lastRequest!.context?.name, '我的收藏');

    // 搜索按钮展开搜索栏，仅此时输入框占位。
    await openSearch(tester);
    expect(find.byType(M3ETextField), findsOneWidget);
    await tester.enterText(find.byType(M3ETextField), 'Artist Song A');
    await tester.pumpAndSettle();
    expect(headlines(tester), ['Song A']);

    // 退出搜索：过滤清空、输入框收起。
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(M3ETextField), findsNothing);
    expect(headlines(tester), ['Song B', 'Song A', 'Song C']);

    // 排序入口在搜索行 ⋮ 菜单；可见顺序即播放队列顺序。
    await openSearch(tester);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按标题'));
    await tester.pumpAndSettle();
    expect(headlines(tester), ['Song A', 'Song B', 'Song C']);
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

  testWidgets('窄屏（320 逻辑宽）不溢出：按钮/搜索入口/列表可渲染', (tester) async {
    await seedFavorites(tester);
    tester.view.physicalSize = const Size(320, 640);
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

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byIcon(Icons.shuffle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
  });

  testWidgets('大屏（1600 宽）头部保持可读宽度，列表完整渲染', (tester) async {
    await seedFavorites(tester);
    tester.view.physicalSize = const Size(1600, 900);
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

    expect(tester.takeException(), isNull);
    expect(headlines(tester), ['Song B', 'Song A', 'Song C']);
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

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pumpAndSettle();
    expect(backend.lastRequest!.context?.name, 'love');
    expect(backend.lastRequest!.tracks, hasLength(3));
  });

  testWidgets('合集弹层：拖动把手自定义顺序并持久化', (tester) async {
    await seedFavorites(tester);
    await importLove(tester);
    await pumpFavorites(tester);

    await openCollectionPicker(tester);
    expect(
      pickerHeadlines(tester),
      ['新建列表', '导入收藏夹', '我的收藏', '播放历史', 'love'],
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
      ['新建列表', '导入收藏夹', '我的收藏', 'love', '播放历史'],
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
    await tester.tap(find.text('新建列表'));
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
      ['新建列表', '导入收藏夹', '我的收藏', '播放历史', 'love'],
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
      ['新建列表', '导入收藏夹', '我的收藏', '播放历史'],
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

  testWidgets('合集弹层：导入收藏夹入口（文件导入选择）', (tester) async {
    await seedFavorites(tester);
    await pumpFavorites(tester);

    await openCollectionPicker(tester);
    await tester.tap(find.text('导入收藏夹'));
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
    await tester.tap(find.text('导入收藏夹'));
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

    expect(find.byType(M3ETextField), findsNothing);
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
    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
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

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
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
