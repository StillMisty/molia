import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/artist.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/artist_page.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_library_repository.dart';
import 'support/fakes.dart';

/// 歌手页：头部（头像 / 名字 / 简介）/ 播放全部 / 加入列表 / 滚到底分页 /
/// 空态 / 失败重试。
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

  /// 打开 split button 的尾部菜单：点击控件右缘即菜单触发器。
  Future<void> openSplitMenu(WidgetTester tester, Key key) async {
    final rect = tester.getRect(find.byKey(key));
    await tester.tapAt(Offset(rect.right - 16, rect.center.dy));
    await tester.pumpAndSettle();
  }

  Track trackOf(String id) => Track(
        id: TrackId('wy', id),
        title: '曲目 $id',
        artists: const [Artist(name: '歌手', id: '6452')],
        album: '专辑名',
        duration: const Duration(seconds: 245),
        origin: TrackOrigin.builtin,
      );

  ArtistDetail artistOf(
    int page, {
    int perPage = 8,
    bool hasMore = true,
    String name = '歌手名',
    String description = '简介文字',
  }) =>
      ArtistDetail(
        id: '6452',
        name: name,
        avatarUrl: 'http://img/avatar.jpg',
        description: description,
        tracks: [for (var i = 0; i < perPage; i++) trackOf('$page-$i')],
        hasMore: hasMore,
      );

  Future<void> pumpPage(
    WidgetTester tester,
    ArtistPageLoader loader, {
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
          home: ArtistPage(loader: loader, fallbackName: fallbackName),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('头部：名字 / 曲目数 / 简介；播放全部进入队列（上下文为歌手名）',
      (tester) async {
    await pumpPage(tester, (page) async => artistOf(page));

    expect(find.text('歌手名'), findsOneWidget);
    expect(find.text('8 首歌曲'), findsOneWidget);
    expect(find.text('简介文字'), findsOneWidget);
    expect(find.byKey(const Key('artistPlayAll')), findsOneWidget);

    // 「加入列表 / 随机播放全部」在主操作的尾部菜单里（split button）。
    await openSplitMenu(tester, const Key('artistPlayAll'));
    expect(find.text('随机播放全部'), findsOneWidget);
    expect(find.text('加入列表'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('artistPlayAll')));
    await tester.pump();
    expect(backend.lastRequest?.startIndex, 0);
    expect(backend.lastRequest?.tracks, hasLength(8));
    expect(backend.lastRequest?.context?.name, '歌手名');
  });

  testWidgets('单曲行：点击从该曲开始播放（队列上下文为歌手名）', (tester) async {
    await pumpPage(tester, (page) async => artistOf(page));

    await tester.tap(find.text('曲目 1-1'));
    await tester.pump();
    expect(backend.lastRequest?.startIndex, 1);
    expect(backend.lastRequest?.context?.name, '歌手名');
  });

  testWidgets('平台未返回歌手名：回退入口携带的名称', (tester) async {
    await pumpPage(
      tester,
      (page) async => artistOf(page, name: ''),
      fallbackName: '入口歌手名',
    );
    expect(find.text('入口歌手名'), findsOneWidget);
  });

  testWidgets('无简介（平台不提供）：不渲染简介区', (tester) async {
    await pumpPage(
      tester,
      (page) async => artistOf(page, description: ''),
    );
    expect(find.text('简介文字'), findsNothing);
    expect(find.text('歌手名'), findsOneWidget);
  });

  testWidgets('无头像：渲染占位图标', (tester) async {
    await pumpPage(
      tester,
      (page) async => ArtistDetail(
        id: '6452',
        name: '歌手名',
        tracks: [trackOf('1-0')],
      ),
    );
    expect(find.byIcon(Icons.person_rounded), findsOneWidget);
  });
}
