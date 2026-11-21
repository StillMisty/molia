import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/covers/custom_cover_store.dart';
import 'package:molia/widgets/playback_cover_decode.dart';
import 'package:molia/widgets/player_cover_deck.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

/// 只替换索引查询与 revision 的封面存储：换图用例不碰真实文件 I/O。
class _RevisionCoverStore extends CustomCoverStore {
  final Map<String, String> customUrls = <String, String>{};

  @override
  String? get defaultCoverUrl => null;

  @override
  String? customCoverUrlForKey(String key) => customUrls[key];
}

Track _track(String id, {String? artwork}) => Track(
  id: TrackId('test', id),
  title: 'Track $id',
  artists: const [Artist(name: 'Deck Artist')],
  album: 'Deck Album',
  duration: const Duration(minutes: 3),
  artwork: artwork == null ? null : Artwork(uri: Uri.parse(artwork)),
  origin: TrackOrigin.builtin,
);

PlaybackSnapshot _snapshotFor(
  List<Track> queue,
  int index, {
  bool isPlaying = true,
}) {
  final current = queue[index];
  return PlaybackSnapshot(
    current: current,
    queue: queue,
    currentIndex: index,
    previous: index > 0 ? queue[index - 1] : null,
    previousOfPrevious: index > 1 ? queue[index - 2] : null,
    next: index + 1 < queue.length ? queue[index + 1] : null,
    upNext: queue.sublist(index + 1),
    upNextIndices: [for (var i = index + 1; i < queue.length; i++) i],
    isPlaying: isPlaying,
    duration: current.duration ?? Duration.zero,
  );
}

Widget _host({
  required PlaybackProvider playback,
  required CustomCoverStore covers,
  required Widget Function(Track? displayTrack) buildDeck,
  bool tickerEnabled = true,
}) {
  return MultiProvider(
    providers: [
      Provider<CustomCoverStore>.value(value: covers),
      ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
    ],
    child: M3EMaterialApp(
      data: M3EThemeData.fromMaterial(ThemeData.light()),
      theme: ThemeData.light(),
      home: Scaffold(
        body: Center(
          child: TickerMode(
            enabled: tickerEnabled,
            child: SizedBox(
              width: 360,
              height: 420,
              child: Consumer<PlaybackProvider>(
                builder: (context, playback, _) =>
                    buildDeck(playback.snapshot.current),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 让弹簧 / 淡换连续走若干帧（单帧大步长不会让 motor 完成落位）。
Future<void> _pumpFrames(
  WidgetTester tester, {
  int frames = 40,
  Duration interval = const Duration(milliseconds: 20),
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(interval);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackFacade backend;
  late PlaybackProvider playback;
  late List<Track> queue;
  final List<bool> swapped = [];

  setUp(() => SharedPreferences.setMockInitialValues({}));

  setUp(() {
    queue = [
      _track('previous'),
      _track('current', artwork: 'https://example.com/current.jpg'),
      _track('next'),
      _track('next-next'),
    ];
    backend = FakePlaybackFacade();
    backend.emit(_snapshotFor(queue, 1));
    playback = buildTestPlaybackProvider(facade: backend);
    swapped.clear();
  });

  tearDown(() => playback.dispose());

  Future<CustomCoverStore> pumpDeck(
    WidgetTester tester, {
    CustomCoverStore? covers,
    bool tickerEnabled = true,
  }) async {
    final store = covers ?? CustomCoverStore();
    await tester.pumpWidget(
      _host(
        playback: playback,
        covers: store,
        tickerEnabled: tickerEnabled,
        buildDeck: (displayTrack) => PlayerCoverDeck(
          displayTrack: displayTrack ?? queue[1],
          artDimension: 280,
          stackDimension: 360,
          stackHeight: 360,
          onTrackSwapped: swapped.add,
        ),
      ),
    );
    await tester.pump();
    return store;
  }

  testWidgets('初始三槽位按快照身份渲染', (tester) async {
    await pumpDeck(tester);

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(PlayerCoverDeck.sideCoverCardKey(left: true, id: queue[0].id)),
      findsOneWidget,
    );
    expect(
      find.byKey(
        PlayerCoverDeck.sideCoverCardKey(left: false, id: queue[2].id),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(PlayerCoverDeck.centerCoverTrackKey(queue[1].id)),
      findsOneWidget,
    );
  });

  testWidgets('拖动超过提交阈值请求切歌并在对账后联动父级', (tester) async {
    await pumpDeck(tester);

    await tester.drag(
      find.byKey(PlayerCoverDeck.swipeHostKey),
      const Offset(-200, 0),
    );
    await tester.pump();
    // 真实会话落盘 / 通知是真实异步，假时钟不驱动它。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(backend.calls, contains('next'));

    // 对账：后端把当前曲目换成下一首，deck 落位并通知父级。
    backend.emit(_snapshotFor(queue, 2));
    await tester.pump();
    await _pumpFrames(tester);

    expect(swapped, isNotEmpty);
    expect(swapped.last, isFalse);
    expect(
      find.byKey(PlayerCoverDeck.centerCoverTrackKey(queue[2].id)),
      findsOneWidget,
    );
  });

  testWidgets('拖动未过阈值回弹且不请求切歌', (tester) async {
    await pumpDeck(tester);

    await tester.drag(
      find.byKey(PlayerCoverDeck.swipeHostKey),
      const Offset(-40, 0),
    );
    await tester.pump();
    await _pumpFrames(tester);

    expect(backend.calls, isNot(contains('next')));
    expect(swapped, isEmpty);
    expect(
      find.byKey(PlayerCoverDeck.centerCoverTrackKey(queue[1].id)),
      findsOneWidget,
    );
  });

  testWidgets('空闲期下一首换人时新旧槽位卡交叉淡化后收尾', (tester) async {
    await pumpDeck(tester);
    final otherNext = _track('other-next');

    backend.emit(
      PlaybackSnapshot(
        current: queue[1],
        queue: queue,
        currentIndex: 1,
        previous: queue[0],
        next: otherNext,
        upNext: [otherNext],
        isPlaying: true,
        duration: queue[1].duration ?? Duration.zero,
      ),
    );
    await tester.pump();

    // 淡换起手帧：旧身份淡出、新身份淡入同时存在。
    expect(
      find.byKey(
        PlayerCoverDeck.sideCoverCardKey(left: false, id: queue[2].id),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        PlayerCoverDeck.sideCoverCardKey(left: false, id: otherNext.id),
      ),
      findsOneWidget,
    );

    await _pumpFrames(tester, frames: 30);
    expect(
      find.byKey(
        PlayerCoverDeck.sideCoverCardKey(left: false, id: queue[2].id),
      ),
      findsNothing,
    );
    expect(
      find.byKey(
        PlayerCoverDeck.sideCoverCardKey(left: false, id: otherNext.id),
      ),
      findsOneWidget,
    );
  });

  testWidgets('同 id 换图期间旧图卡存在，淡出后收尾', (tester) async {
    await pumpDeck(tester);
    final updated = _track(
      'current',
      artwork: 'https://example.com/current-new.jpg',
    );

    backend.emit(
      PlaybackSnapshot(
        current: updated,
        queue: queue,
        currentIndex: 1,
        previous: queue[0],
        previousOfPrevious: null,
        next: queue[2],
        upNext: [queue[2], queue[3]],
        upNextIndices: const [2, 3],
        isPlaying: true,
        duration: updated.duration ?? Duration.zero,
      ),
    );
    await tester.pump();

    expect(find.byKey(PlayerCoverDeck.outgoingArtworkCardKey), findsOneWidget);
    expect(
      find.byKey(PlayerCoverDeck.centerCoverTrackKey(queue[1].id)),
      findsOneWidget,
    );

    await _pumpFrames(tester, frames: 30);
    expect(find.byKey(PlayerCoverDeck.outgoingArtworkCardKey), findsNothing);
    expect(
      find.byKey(PlayerCoverDeck.centerCoverTrackKey(queue[1].id)),
      findsOneWidget,
    );
  });

  testWidgets('弹簧途中再次切歌走连续接管并最终落位', (tester) async {
    await pumpDeck(tester);

    backend.emit(_snapshotFor(queue, 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    // 上一段弹簧仍在途中：新会话应捕获当前视觉继续，而不是从 0 重播。
    backend.emit(_snapshotFor(queue, 3));
    await tester.pump();
    await _pumpFrames(tester, frames: 60);

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(PlayerCoverDeck.centerCoverTrackKey(queue[3].id)),
      findsOneWidget,
    );
  });

  testWidgets('快速连续切歌与卸载不抛异常', (tester) async {
    await pumpDeck(tester);

    backend.emit(_snapshotFor(queue, 2));
    await tester.pump(const Duration(milliseconds: 16));
    backend.emit(_snapshotFor(queue, 3));
    await tester.pump(const Duration(milliseconds: 16));
    backend.emit(_snapshotFor(queue, 1));
    await tester.pump(const Duration(milliseconds: 16));

    // 高频通知节流器 / 弹簧仍在途：先让测试时钟走到定时器之后，再卸载。
    await _pumpFrames(tester, frames: 20);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
  });

  testWidgets('自定义封面 revision 变化后中心卡仍渲染', (tester) async {
    final covers = _RevisionCoverStore();
    await pumpDeck(tester, covers: covers);
    expect(
      find.byKey(PlayerCoverDeck.centerCoverTrackKey(queue[1].id)),
      findsOneWidget,
    );

    covers.customUrls[queue[1].id.uri] = 'https://example.com/custom-cover.jpg';
    covers.revision.value++;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(PlayerCoverDeck.centerCoverTrackKey(queue[1].id)),
      findsOneWidget,
    );
  });

  testWidgets('TickerMode 关闭时直接落位且不崩溃', (tester) async {
    await pumpDeck(tester, tickerEnabled: false);

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(PlayerCoverDeck.centerCoverTrackKey(queue[1].id)),
      findsOneWidget,
    );
  });

  group('playbackCoverDecodeEdgeFor', () {
    int edge(double shortestSide, {double dpr = 1}) =>
        playbackCoverDecodeEdgeFor(dpr: dpr, shortestSide: shortestSide);

    test('同一档内短边变化不换解码键', () {
      // 桌面拖动窗口时短边连续变化，同一档内必须复用同一张已解码图。
      expect(edge(400), edge(401));
      expect(edge(400), edge(500));
      expect(edge(500), edge(512));
      expect(edge(513), edge(599));
    });

    test('档位边界向上取档', () {
      // 向上而不是就近：解码边长不能小于显示需求，否则放大后发糊。
      expect(edge(200), 256);
      expect(edge(0), 256);
      expect(edge(256), 256);
      expect(edge(257), 384);
      expect(edge(384), 384);
      expect(edge(385), 512);
      expect(edge(512), 512);
      expect(edge(513), 600);
    });

    test('短边 >= 600 稳定在 600 档', () {
      expect(edge(600), 600);
      expect(edge(601), 600);
      expect(edge(900), 600);
      expect(edge(2400), 600);
    });

    test('DPR 变化仍换解码键', () {
      // 档位只按逻辑短边取；DPR 是档位之外的独立乘数（跨屏拖动时物理
      // 像素需求确实变了，不能沿用旧图）。
      expect(edge(400, dpr: 1), 512);
      expect(edge(400, dpr: 1.5), 768);
      expect(edge(400, dpr: 2), 1024);
    });

    test('最小窗口（短边 400）解码边长不小于显示需求', () {
      for (final dpr in [1.0, 1.5, 2.0, 2.625, 3.0]) {
        final decoded = edge(400, dpr: dpr);
        expect(decoded / dpr, greaterThanOrEqualTo(400));
        expect(decoded / dpr, lessThanOrEqualTo(playbackCoverMaxLogicalEdge));
      }
    });
  });
}
