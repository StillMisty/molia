import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/track_handoff.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

/// 曲目交接模块：纯归一（名称 / 起播下标 / 批量 addedAt）与两个意图
/// （播放一组曲目、加入资料库）的接线。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('纯归一', () {
    test('上下文名：trim 后取列表名，空名回退入口名', () {
      expect(
        resolveTrackListName(name: '  专辑名  ', fallbackName: '入口名'),
        '专辑名',
      );
      expect(
        resolveTrackListName(name: '   ', fallbackName: '  入口名  '),
        '入口名',
      );
      expect(resolveTrackListName(name: null, fallbackName: '   '), '');
    });

    test('起播下标：显式下标夹取；洗牌用注入的随机源', () {
      expect(resolveTrackStartIndex(length: 10, startIndex: 4), 4);
      expect(resolveTrackStartIndex(length: 10, startIndex: -1), 0);
      expect(resolveTrackStartIndex(length: 10, startIndex: 99), 9);
      expect(resolveTrackStartIndex(length: 0, shuffle: true), 0);

      final expected = math.Random(7).nextInt(8);
      expect(
        resolveTrackStartIndex(
          length: 8,
          shuffle: true,
          random: math.Random(7),
        ),
        expected,
      );
    });

    test('批量转换：全部曲目共用一个 addedAt，payload / 歌手口径保留', () {
      final tracks = [
        const Track(
          id: TrackId('kw', 'a'),
          title: '甲曲',
          artists: [Artist(name: '甲'), Artist(name: '乙')],
          album: '专辑',
          duration: Duration(seconds: 90),
          origin: TrackOrigin.builtin,
          payload: {'songmid': 'a'},
        ),
        const Track(
          id: TrackId('kw', 'b'),
          title: '乙曲',
          origin: TrackOrigin.builtin,
          payload: {'songmid': 'b'},
        ),
      ];

      final rows = playlistTracksFrom(tracks, addedAt: 42);

      expect(rows, hasLength(2));
      expect([for (final row in rows) row.addedAt], [42, 42]);
      expect(rows[0].artist, '甲, 乙');
      expect(rows[0].album, '专辑');
      expect(rows[0].durationMs, 90000);
      // payload 浅拷贝原样透传：取链依赖平台字段（不是 UI 重新拼的对象）。
      expect(rows[0].raw, {'songmid': 'a'});
      expect(rows[1].raw, {'songmid': 'b'});
    });
  });

  group('交接意图（provider 假实现）', () {
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
          id: TrackId('kw', id),
          title: '曲目 $id',
          artists: [Artist(name: '歌手 $id')],
          album: '专辑名',
          duration: const Duration(seconds: 30),
          origin: TrackOrigin.builtin,
          payload: {'songmid': id},
        );

    Future<void> pumpHost(
      WidgetTester tester, {
      Future<void> Function(BuildContext context)? play,
      Future<bool> Function(BuildContext context)? add,
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
              body: Builder(
                builder: (context) => Column(
                  children: [
                    if (play != null)
                      TextButton(
                        onPressed: () => unawaited(play(context)),
                        child: const Text('play'),
                      ),
                    if (add != null)
                      TextButton(
                        onPressed: () => unawaited(add(context)),
                        child: const Text('add'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('播放：按下标装载整表，上下文名 trim 后进队列', (tester) async {
      const handoff = TrackHandoff();
      final tracks = [trackOf('a'), trackOf('b'), trackOf('c')];

      await pumpHost(
        tester,
        play: (context) => handoff.play(
          context,
          tracks,
          startIndex: 1,
          contextName: '  专辑名  ',
          fallbackContextName: '入口名',
        ),
      );

      await tester.tap(find.text('play'));
      await tester.pumpAndSettle();

      expect(backend.calls, ['load']);
      expect(backend.lastRequest?.startIndex, 1);
      expect(
        [for (final track in backend.lastRequest!.tracks) track.id.id],
        ['a', 'b', 'c'],
      );
      expect(backend.lastRequest?.context?.name, '专辑名');
    });

    testWidgets('随机播放：先落 shuffle 模式，再按注入随机源取起点装载', (tester) async {
      final handoff = TrackHandoff(random: math.Random(7));
      final tracks = [for (var i = 0; i < 8; i++) trackOf('$i')];
      final expectedStart = math.Random(7).nextInt(8);

      await pumpHost(
        tester,
        play: (context) => handoff.play(
          context,
          tracks,
          shuffle: true,
          contextName: '专辑名',
        ),
      );

      await tester.tap(find.text('play'));
      await tester.pumpAndSettle();

      // 洗牌排列在装载时按当前模式生成：setMode 必须在 load 之前。
      expect(backend.calls, ['setMode', 'load']);
      expect(playback.currentMode, PlayMode.shuffle);
      expect(backend.lastRequest?.startIndex, expectedStart);
      expect(backend.lastRequest?.context?.name, '专辑名');
    });

    testWidgets('空列表：播放与加入列表都不动作', (tester) async {
      const handoff = TrackHandoff();
      bool? added;

      await pumpHost(
        tester,
        play: (context) => handoff.play(context, const []),
        add: (context) async {
          added = await handoff.addToLibrary(context, const []);
          return added!;
        },
      );

      await tester.tap(find.text('play'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('add'));
      await tester.pumpAndSettle();

      expect(backend.calls, isEmpty);
      expect(backend.lastRequest, isNull);
      expect(added, isFalse);
      expect(find.text('我的收藏'), findsNothing);
      expect(await repository.listPlaylists(), isEmpty);
    });

    testWidgets('加入列表：批量归一，全批共用一个 addedAt', (tester) async {
      const handoff = TrackHandoff();
      final tracks = [trackOf('a'), trackOf('b')];
      bool? added;

      await pumpHost(
        tester,
        add: (context) async {
          added = await handoff.addToLibrary(context, tracks);
          return added!;
        },
      );

      await tester.tap(find.text('add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的收藏'));
      await tester.pumpAndSettle();

      expect(added, isTrue);
      final favorites = await repository.findPlaylistByName('__favorites__');
      final rows = await repository.listPlaylistTracks(favorites!.id);
      expect([for (final row in rows) row.key], ['kw:a', 'kw:b']);
      expect(rows[0].addedAt, rows[1].addedAt);
      expect(rows[0].artist, '歌手 a');
      expect(rows[0].raw, {'songmid': 'a'});
    });

    testWidgets('单曲加入：同一个意图走统一目标弹层', (tester) async {
      const handoff = TrackHandoff();
      bool? added;

      await pumpHost(
        tester,
        add: (context) async {
          added = await handoff.addToLibrary(context, [trackOf('solo')]);
          return added!;
        },
      );

      await tester.tap(find.text('add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的收藏'));
      await tester.pumpAndSettle();

      expect(added, isTrue);
      expect(await repository.favoriteKeys(), {'kw:solo'});
    });
  });
}
