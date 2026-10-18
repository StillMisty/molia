import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/favorite_track_tile.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

/// 收藏曲目行（歌手页 / 专辑页 / 搜索结果共用的唯一适配层）：
/// 行内容词表（[Track.artistLabel]）+ 收藏态订阅 + 操作菜单动作接线
/// （触摸端行尾 ⋮ / 桌面行表面右键）。
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

  const track = Track(
    id: TrackId('kw', 'a'),
    title: 'Title a',
    // 空名被过滤；多歌手按 `, ` 词表连接。
    artists: [Artist(name: 'A'), Artist(name: ''), Artist(name: 'B')],
    album: 'Album',
    duration: Duration(seconds: 245),
    origin: TrackOrigin.builtin,
    payload: {'songmid': 'a'},
  );

  Future<void> pumpTile(
    WidgetTester tester, {
    VoidCallback? onToggleFavorite,
    VoidCallback? onAddToPlaylist,
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
          home: Scaffold(
            body: FavoriteTrackTile.track(
              track: track,
              fallbackCoverUrl: 'http://img/fallback.jpg',
              position: M3ECardPosition.single,
              onTap: () {},
              onToggleFavorite: onToggleFavorite ?? () {},
              onAddToPlaylist: onAddToPlaylist ?? () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('领域曲目构造：标题 / 歌手标签 / 时长取领域值', (tester) async {
    await pumpTile(tester);

    expect(find.text('Title a'), findsOneWidget);
    expect(find.text('A, B'), findsOneWidget);
    expect(find.text('4:05'), findsOneWidget);
  });

  testWidgets('收藏态订阅：菜单动作写库后，重开菜单文案跟随（取消收藏）', (tester) async {
    await pumpTile(
      tester,
      onToggleFavorite: () => unawaited(library.toggleFavoriteTrack(track)),
    );

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    expect(find.text('收藏'), findsOneWidget);

    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(library.isFavorite('kw', 'a'), isTrue);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    expect(find.text('取消收藏'), findsOneWidget, reason: '订阅到收藏态变化');
  });

  testWidgets('行尾菜单动作：收藏 / 加入列表接线到注入回调', (tester) async {
    var toggled = 0;
    var added = 0;
    await pumpTile(
      tester,
      onToggleFavorite: () => toggled++,
      onAddToPlaylist: () => added++,
    );

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(toggled, 1);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入列表'));
    await tester.pumpAndSettle();
    expect(added, 1);
  });

  testWidgets(
    '桌面：行内无 ⋮，右键在落点弹出同一份菜单（适配层不吞桌面入口）',
    (tester) async {
      await pumpTile(tester);

      expect(
        find.byIcon(Icons.more_vert_rounded),
        findsNothing,
        reason: '桌面入口是行表面右键，不再有行尾 ⋮',
      );

      await tester.tapAt(
        tester.getRect(find.byType(TrackRow)).center,
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('加入列表'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('通用构造：artists 链接渲染与点击回调透传（搜索结果行契约）', (tester) async {
    var rowTaps = 0;
    final tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        home: Scaffold(
          body: FavoriteTrackTile(
            title: 'Title a',
            artist: 'A、B',
            artists: [
              TrackRowArtist(name: 'A', onTap: () => tapped.add('A')),
              const TrackRowArtist(name: 'B'),
            ],
            position: M3ECardPosition.single,
            onTap: () => rowTaps++,
            favoriteOf: (_) => false,
            onToggleFavorite: () {},
            onAddToPlaylist: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tapOnText(find.textRange.ofSubstring('A'));
    await tester.pump();
    expect(tapped, ['A']);
    expect(rowTaps, 0, reason: '歌手链接不触发行播放');
  });
}
