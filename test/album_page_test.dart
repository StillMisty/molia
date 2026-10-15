import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/album.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/album_page.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_library_repository.dart';
import 'support/fakes.dart';

/// 专辑页：头部元信息 / 播放全部 / 加入列表 / 滚到底分页 / 空态 / 失败重试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLibraryRepository repository;
  late FakePlaybackBackend backend;
  late PlaybackProvider playback;
  late LibraryProvider library;

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
  });

  tearDown(() async {
    library.dispose();
    playback.dispose();
    await repository.dispose();
  });

  Track trackOf(String id) => Track(
        id: TrackId('wy', id),
        title: '曲目 $id',
        artists: const [Artist(name: '歌手')],
        album: '专辑名',
        duration: const Duration(seconds: 245),
        origin: TrackOrigin.builtin,
      );

  Album albumOf(
    int page, {
    int perPage = 8,
    bool hasMore = true,
    String name = '专辑名',
  }) =>
      Album(
        id: '32311',
        name: name,
        artist: '歌手',
        coverUrl: 'http://img/cover.jpg',
        year: 2012,
        tracks: [for (var i = 0; i < perPage; i++) trackOf('$page-$i')],
        hasMore: hasMore,
      );

  Future<void> pumpPage(
    WidgetTester tester,
    AlbumPageLoader loader, {
    String? fallbackName,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          ChangeNotifierProvider<LibraryProvider>.value(value: library),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: AlbumPage(loader: loader, fallbackName: fallbackName),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('头部：专辑名 / 歌手 / 年份 / 曲目数；播放全部进入队列', (tester) async {
    await pumpPage(tester, (page) async => albumOf(page));

    expect(find.text('专辑名'), findsOneWidget);
    expect(find.text('歌手 · 2012 年 · 8 首'), findsOneWidget);
    expect(find.byKey(const Key('albumPlayAll')), findsOneWidget);
    expect(find.byKey(const Key('albumAddToLibrary')), findsOneWidget);

    await tester.tap(find.byKey(const Key('albumPlayAll')));
    await tester.pump();
    expect(backend.lastRequest?.startIndex, 0);
    expect(backend.lastRequest?.tracks, hasLength(8));
    expect(backend.lastRequest?.context?.name, '专辑名');
  });

  testWidgets('曲目行：与搜索页同款行尾菜单（收藏 / 加入列表）', (tester) async {
    await pumpPage(tester, (page) async => albumOf(page));

    // 行尾菜单存在（每行一个）。
    expect(find.byIcon(Icons.more_vert_rounded), findsWidgets);

    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('加入列表'), findsWidgets);

    await tester.tap(find.text('收藏').last);
    await tester.pumpAndSettle();
    expect(await repository.favoriteKeys(), hasLength(1), reason: '行菜单收藏写入仓库');
  });

  testWidgets('曲目行菜单：加入列表走目标选择流程', (tester) async {
    await pumpPage(tester, (page) async => albumOf(page));

    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入列表').last);
    await tester.pumpAndSettle();
    expect(find.text('我的收藏'), findsOneWidget);

    await tester.tap(find.text('我的收藏'));
    await tester.pumpAndSettle();
    expect(await repository.favoriteKeys(), hasLength(1));
  });

  testWidgets('单曲行：点击从该曲开始播放（队列上下文为专辑名）', (tester) async {
    await pumpPage(tester, (page) async => albumOf(page));

    await tester.tap(find.text('曲目 1-1'));
    await tester.pump();
    expect(backend.lastRequest?.startIndex, 1);
    expect(backend.lastRequest?.context?.name, '专辑名');
  });

  testWidgets('滚到底自动加载下一页；末页停止', (tester) async {
    final calls = <int>[];
    await pumpPage(tester, (page) async {
      calls.add(page);
      return albumOf(page, hasMore: page < 2);
    });
    expect(calls, [1]);
    expect(find.text('歌手 · 2012 年 · 8 首'), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(calls, [1, 2]);

    // 末页（hasMore=false）后不再请求。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(calls, [1, 2]);
  });

  testWidgets('加载更多失败：底部重试按钮可重试', (tester) async {
    final calls = <int>[];
    await pumpPage(tester, (page) async {
      calls.add(page);
      if (page == 2) throw StateError('boom');
      return albumOf(page);
    });

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(calls, [1, 2]);
    expect(find.text('重试'), findsOneWidget);

    await tester.ensureVisible(find.text('重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(calls, [1, 2, 2]);
  });

  testWidgets('空专辑：空态文案', (tester) async {
    await pumpPage(
      tester,
      (page) async => albumOf(page, perPage: 0, hasMore: false),
    );
    expect(find.text('该专辑暂无歌曲'), findsOneWidget);
    expect(find.byKey(const Key('albumPlayAll')), findsNothing);
  });

  testWidgets('加载失败：错误态 + 重试成功', (tester) async {
    var fail = true;
    await pumpPage(tester, (page) async {
      if (fail) throw StateError('boom');
      return albumOf(page);
    });
    expect(find.text('专辑加载失败'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('专辑名'), findsOneWidget);
    expect(find.text('专辑加载失败'), findsNothing);
  });

  testWidgets('加入列表：弹层选择收藏后批量写入', (tester) async {
    await pumpPage(tester, (page) async => albumOf(page));

    await tester.tap(find.byKey(const Key('albumAddToLibrary')));
    await tester.pumpAndSettle();
    expect(find.text('我的收藏'), findsOneWidget);

    await tester.tap(find.text('我的收藏'));
    await tester.pumpAndSettle();
    expect(await repository.favoriteKeys(), hasLength(8));
  });

  testWidgets('平台未返回专辑名：回退入口携带的名称', (tester) async {
    await pumpPage(
      tester,
      (page) async => albumOf(page, name: ''),
      fallbackName: '入口专辑名',
    );
    expect(find.text('入口专辑名'), findsOneWidget);
  });
}
