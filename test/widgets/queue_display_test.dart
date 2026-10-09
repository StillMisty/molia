import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:molia/widgets/queue.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

/// 队列显示：只列出「接下来」；当前曲目由上方播放器承载，不在列表重复。
///
/// 懒加载：队列行是固定行高的 [TrackRow]，长队列只构建视口附近的行；
/// 滚动条常显且可手拖（interactive + thumbVisibility）。
///
/// 注意：provider 必须在测试体内创建（不要在 setUp 里）——setUp 在测试的
/// FakeAsync zone 之外运行，其异步链会跨 zone，await preferencesReady 后
/// 再 pump 会卡死（与 settings_page_test 同一约定）。
Track _track(String id) => Track(
      id: TrackId('fake', id),
      title: 'Title $id',
      artists: [Artist(name: 'Artist $id')],
      album: 'Album $id',
      duration: const Duration(seconds: 30),
      origin: TrackOrigin.lx,
      payload: {'id': id, 'songmid': 'mid_$id'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<ScrollController> pumpQueue(
    WidgetTester tester,
    PlaybackProvider playback,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<PlaybackProvider>.value(
        value: playback,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(
            body: QueueDisplay(controller: controller),
          ),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  /// 通知节流计时器跑完（queue 分类 300ms），避免 pending timer 报错。
  Future<void> drainThrottle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 400));

  BackendSnapshot upcomingSnapshot(List<Track> queue, {int index = 0}) =>
      BackendSnapshot(
        current: queue[index],
        queue: queue,
        currentIndex: index,
        next: index + 1 < queue.length ? queue[index + 1] : null,
        upcoming: queue.sublist(index + 1),
        upNext: queue.sublist(index + 1),
        isPlaying: true,
        position: Duration.zero,
        duration: const Duration(seconds: 30),
      );

  testWidgets('只列出接下来：当前曲目不重复出现在列表（圆角封面/统一字号）', (tester) async {
    final backend = FakePlaybackBackend();
    final playback = buildTestPlaybackProvider(backend: backend);
    addTearDown(playback.dispose);

    backend.emit(BackendSnapshot(
      current: _track('a'),
      queue: [_track('a'), _track('b')],
      currentIndex: 0,
      next: _track('b'),
      upcoming: [_track('b')],
      upNext: [_track('b')],
      isPlaying: true,
      position: Duration.zero,
      duration: const Duration(seconds: 30),
    ));
    await pumpQueue(tester, playback);

    expect(tester.takeException(), isNull);
    // 当前曲目只在播放器里，列表页不重复。
    expect(find.text('正在播放'), findsNothing);
    expect(find.text('Title a'), findsNothing);
    expect(find.text('接下来'), findsOneWidget);
    expect(find.text('Title b'), findsOneWidget);
    // 播放指示（均衡器图形）随「正在播放」行一起移除；时长走固定行尾。
    expect(find.byIcon(Icons.graphic_eq_rounded), findsNothing);
    expect(find.text('0:30'), findsOneWidget);

    await drainThrottle(tester);
  });

  testWidgets('恢复态：列表只有接下来，点条目从该曲目恢复播放', (tester) async {
    // 先写入会话，再创建 provider（构造时即读取）。
    await PlaybackSessionStore().save(PlaybackSession(
      tracks: [_track('a'), _track('b')],
      index: 0,
      position: const Duration(seconds: 10),
    ));

    final backend = FakePlaybackBackend();
    final playback = buildTestPlaybackProvider(backend: backend);
    addTearDown(playback.dispose);
    await playback.preferencesReady;
    await pumpQueue(tester, playback);

    // 恢复的当前曲目同样不在列表重复；只有接下来的 b。
    expect(find.text('正在播放'), findsNothing);
    expect(find.text('Title a'), findsNothing);
    expect(find.text('Title b'), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsNothing);

    // 点「接下来」条目 → 用会话队列从该曲目恢复播放（而不是静默无响应）。
    await tester.tap(find.text('Title b'));
    await tester.pump();
    await tester.pump();

    expect(backend.calls, contains('load'));
    expect(backend.lastRequest?.startIndex, 1);

    await drainThrottle(tester);
  });

  testWidgets('队列页按 upNext 展示实际播放顺序（shuffle 排列）', (tester) async {
    final backend = FakePlaybackBackend();
    final playback = buildTestPlaybackProvider(backend: backend);
    addTearDown(playback.dispose);

    final a = _track('a');
    final b = _track('b');
    final c = _track('c');
    final d = _track('d');
    backend.emit(BackendSnapshot(
      current: a,
      queue: [a, b, c, d],
      currentIndex: 0,
      next: d,
      // 队列顺序（b、c、d）与实际洗牌顺序（d、c、b）不同。
      upcoming: [b, c, d],
      upNext: [d, c, b],
      isPlaying: true,
      position: Duration.zero,
      duration: const Duration(seconds: 30),
      mode: PlayMode.shuffle,
    ));
    await pumpQueue(tester, playback);

    final titles = tester
        .widgetList<TrackRow>(find.byType(TrackRow))
        .map((row) => row.title)
        .toList();
    expect(titles, ['Title d', 'Title c', 'Title b']);

    await drainThrottle(tester);
  });

  testWidgets('长队列懒加载：只构建视口附近的固定高行', (tester) async {
    final backend = FakePlaybackBackend();
    final playback = buildTestPlaybackProvider(backend: backend);
    addTearDown(playback.dispose);

    final queue = [for (var i = 0; i < 300; i++) _track('$i')];
    backend.emit(upcomingSnapshot(queue));
    await pumpQueue(tester, playback);

    final rows = tester.widgetList<TrackRow>(find.byType(TrackRow)).toList();
    expect(rows.length, lessThan(30), reason: '300 首只构建视口附近的行');
    expect(find.text('Title 299'), findsNothing);

    // 列表使用固定行高：itemExtent = 行高 + 1px 分隔线。
    final sliver = tester.widget<SliverFixedExtentList>(
      find.byType(SliverFixedExtentList),
    );
    expect(sliver.itemExtent, TrackRow.extent + 1);

    await tester.scrollUntilVisible(
      find.text('Title 299'),
      800,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Title 299'), findsOneWidget);

    await drainThrottle(tester);
  });

  testWidgets('滚动条常显且可手拖：按住拇指拖动改变队列滚动位置', (tester) async {
    final backend = FakePlaybackBackend();
    final playback = buildTestPlaybackProvider(backend: backend);
    addTearDown(playback.dispose);

    final queue = [for (var i = 0; i < 60; i++) _track('$i')];
    backend.emit(upcomingSnapshot(queue));
    final controller = await pumpQueue(tester, playback);
    // 等通知节流计时器与滚动条首帧绘制（拇指命中区依赖已计算的 metrics）。
    await drainThrottle(tester);

    final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
    expect(scrollbar.thumbVisibility, isTrue);
    expect(scrollbar.interactive, isTrue);
    expect(scrollbar.controller, controller);

    // 按住顶部拇指向下拖：offset 必须变化（滚动条真能手按滚动）。
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

    await drainThrottle(tester);
  });
}
