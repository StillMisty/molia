import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/discover.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/pages/discover_tracks_page.dart';
import 'package:molia/providers/discover_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:molia/widgets/track_table_header.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_discover_api.dart';
import 'support/fake_library_repository.dart';
import 'support/fakes.dart';

/// 发现详情页：滚到底自动加载下一页（无限滚动），行懒构建 + 固定行高。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLibraryRepository repository;
  late FakePlaybackBackend backend;
  late PlaybackProvider playback;
  late LibraryProvider library;
  late DiscoverProvider discover;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = FakeLibraryRepository();
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(
      backend: backend,
      libraryRepository: repository,
    );
    library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    discover = DiscoverProvider(
      playbackProvider: playback,
      libraryProvider: library,
      sources: {'wy': FakeDiscoverSource()},
    );
  });

  tearDown(() async {
    discover.dispose();
    library.dispose();
    playback.dispose();
    await repository.dispose();
  });

  DiscoverDetail detailFor(int page, {int total = 60, int perPage = 30}) =>
      DiscoverDetail(
        info: DiscoverPlaylist(id: 'x', name: '歌单', trackCount: total),
        tracks: [
          for (var i = 0; i < perPage; i++)
            DiscoverTrack(
              sourceKey: 'wy',
              songId: '$page-$i',
              title: 'P$page-$i',
              artist: '歌手',
            ),
        ],
      );

  /// 元数据齐全的详情（歌手 / 专辑 / 时长）：表格列断言用。
  DiscoverDetail richDetail(int page) => DiscoverDetail(
        info: const DiscoverPlaylist(id: 'x', name: '歌单', trackCount: 30),
        tracks: [
          for (var i = 0; i < 30; i++)
            DiscoverTrack(
              sourceKey: 'wy',
              songId: '$page-$i',
              title: 'P$page-$i',
              artist: '歌手 $i',
              album: '专辑 $i',
              // 逐行不同时长：列断言不靠 findsNWidgets 计数。
              durationMs: 185000 + i * 1000,
            ),
        ],
      );

  Future<void> pumpPage(
    WidgetTester tester,
    DiscoverTracksLoader loader, {
    Size? size,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    }
    await tester.pumpWidget(
      ChangeNotifierProvider<DiscoverProvider>.value(
        value: discover,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: DiscoverTracksPage(title: '歌单', loader: loader),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('随机播放全部：切换 shuffle 模式并从随机曲目起播', (tester) async {
    await pumpPage(tester, (page) async => detailFor(page));

    final split = find.byKey(const Key('discoverTracksPlayAll'));
    expect(split, findsOneWidget);

    // 尾部菜单（split button 右缘即触发器）。
    final rect = tester.getRect(split);
    await tester.tapAt(Offset(rect.right - 16, rect.center.dy));
    await tester.pumpAndSettle();
    await tester.tap(find.text('随机播放全部'));
    await tester.pumpAndSettle();

    expect(backend.lastRequest?.tracks, hasLength(30));
    expect(backend.lastRequest?.context?.name, '歌单');
    expect(backend.lastRequest!.startIndex, inInclusiveRange(0, 29));
    expect(playback.currentMode, PlayMode.shuffle);
  });

  testWidgets('滚到底自动加载下一页；取满总数后停止（无限滚动）', (tester) async {
    final calls = <int>[];
    await pumpPage(tester, (page) async {
      calls.add(page);
      return detailFor(page);
    });

    expect(calls, [1]);
    expect(find.text('P1-0'), findsOneWidget);
    // 头部显示平台总数（不是已加载数量）。
    expect(find.text('60 首'), findsOneWidget);

    // 滚到底部 → 自动加载第 2 页（40 首 = 每页 30，无需再翻第 3 页）。
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -4000),
      4000,
    );
    await tester.pumpAndSettle();
    expect(calls, [1, 2]);

    // 懒构建：60 行只构建视口附近的行。
    final rows = tester.widgetList<TrackRow>(find.byType(TrackRow)).length;
    expect(rows, lessThan(30), reason: '60 首只构建视口附近的行');

    // 已取满（loaded == total）→ 继续滚动不再请求。
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -4000),
      4000,
    );
    await tester.pumpAndSettle();
    expect(calls, [1, 2]);
  });

  testWidgets('平台无总数信息（榜单）：单页加载，不触发翻页', (tester) async {
    final calls = <int>[];
    await pumpPage(tester, (page) async {
      calls.add(page);
      return DiscoverDetail(
        info: const DiscoverPlaylist(id: 'board', name: '热歌榜'),
        tracks: [
          for (var i = 0; i < 30; i++)
            DiscoverTrack(
              sourceKey: 'wy',
              songId: 'b-$i',
              title: 'B$i',
              artist: '歌手',
            ),
        ],
      );
    });

    expect(calls, [1]);
    expect(find.text('30 首'), findsOneWidget);
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -4000),
      4000,
    );
    await tester.pumpAndSettle();
    expect(calls, [1], reason: '无总数信息时不翻页');
  });

  testWidgets('桌面宽屏：曲目列表渲染表格表头 + 三列，列左缘与表头对齐', (tester) async {
    await pumpPage(
      tester,
      (page) async => richDetail(page),
      size: const Size(1200, 900),
    );

    expect(find.byType(TrackTableHeader), findsOneWidget);
    expect(find.text('艺术家'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('时长'), findsOneWidget);

    // 行内三列：歌手 / 专辑 / 时长（时长不再占行尾）。
    expect(find.text('歌手 0'), findsOneWidget);
    expect(find.text('专辑 0'), findsOneWidget);
    expect(find.text('3:05'), findsOneWidget);

    // 表头存在的意义就是与列对齐：三列左缘必须逐列相同。
    expect(
      tester.getTopLeft(find.text('歌手 0')).dx,
      tester.getTopLeft(find.text('艺术家')).dx,
    );
    expect(
      tester.getTopLeft(find.text('专辑 0')).dx,
      tester.getTopLeft(find.text('专辑')).dx,
    );
    expect(
      tester.getTopLeft(find.text('3:05')).dx,
      tester.getTopLeft(find.text('时长')).dx,
    );

    // 表头钉住：滚过封面头部后停在视口顶部（不随列表滚走）。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(find.text('歌手 0'), findsNothing, reason: '首行已滚出视口');
    expect(find.byType(TrackTableHeader), findsOneWidget);
    final viewportTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
    final pinnedTop = tester.getTopLeft(find.byType(TrackTableHeader)).dy;
    expect(pinnedTop, closeTo(viewportTop, 2), reason: '表头钉在视口顶部');

    // 换一个滚动偏移：表头位置不动（非 pinned 时会继续上滚）。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byType(TrackTableHeader)).dy,
      closeTo(pinnedTop, 2),
      reason: '继续滚动表头钉住不动',
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('桌面窄窗口（< 900）：不渲染表头，行保持单列', (tester) async {
    await pumpPage(
      tester,
      (page) async => richDetail(page),
      size: const Size(800, 2400),
    );

    expect(find.byType(TrackTableHeader), findsNothing);
    expect(find.text('专辑'), findsNothing);
    expect(find.text('专辑 0'), findsNothing, reason: '单列行不展示专辑');
    expect(find.text('歌手 0'), findsOneWidget, reason: '副标题仍是歌手');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('非桌面平台：宽窗口也不渲染表头（行保持单列）', (tester) async {
    // 测试环境默认平台为 android：窗口够宽也不进表格模式。
    await pumpPage(
      tester,
      (page) async => richDetail(page),
      size: const Size(1200, 2400),
    );

    expect(find.byType(TrackTableHeader), findsNothing);
    expect(find.text('专辑 0'), findsNothing);
    expect(find.text('歌手 0'), findsOneWidget);
  });
}
