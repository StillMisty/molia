import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/discover.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/discover_tracks_page.dart';
import 'package:molia/providers/discover_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/track_row.dart';
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

  Future<void> pumpPage(
    WidgetTester tester,
    DiscoverTracksLoader loader,
  ) async {
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
}
