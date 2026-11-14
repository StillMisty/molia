import 'dart:ui' show Tristate;

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/models/lyric_line.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/utils/responsive.dart';
import 'package:molia/widgets/lyrics.dart';
import 'package:molia/widgets/queue.dart';
import 'package:molia/widgets/row_actions.dart';
import 'package:molia/widgets/seek_bar.dart';
import 'package:molia/widgets/seek_preview.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cover_test_support.dart';
import '../support/fake_library_repository.dart';
import '../support/perf_app_harness.dart';
import '../support/fakes.dart';
import '../support/settings_test_support.dart';

class _FakeLyricsProvider extends LyricsProvider {
  _FakeLyricsProvider(this._state);

  final LyricsState _state;

  @override
  LyricsState get state => _state;
}

Widget _app(
  Widget child, {
  bool disableAnimations = false,
  bool reduceMotion = false,
}) {
  return M3EMaterialApp(
    data: M3EThemeData.fromMaterial(ThemeData.light()),
    theme: ThemeData.light(),
    locale: const Locale('zh'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    supportedLocales: const [Locale('zh')],
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: disableAnimations,
          reduceMotion: reduceMotion,
        ),
        child: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('进度滑杆语义', () {
    late ValueNotifier<Duration> position;
    late ChangeNotifier trackChanges;
    late SeekPreviewController controller;
    late List<int> seeks;

    setUp(() {
      position = ValueNotifier(Duration.zero);
      trackChanges = ChangeNotifier();
      seeks = [];
      controller = SeekPreviewController(
        position: position,
        trackChanges: trackChanges,
        currentTrackId: () => const TrackId('kw', '1'),
        seek: (ms) => seeks.add(ms),
      );
    });

    tearDown(() {
      controller.dispose();
      position.dispose();
      trackChanges.dispose();
    });

    Future<void> pump(WidgetTester tester, {bool wavy = false}) async {
      await tester.pumpWidget(
        _app(
          SeekBar(
            controller: controller,
            position: position,
            durationMs: 180000,
            isPlaying: true,
            hasTrack: true,
            timeLabels: SeekTimeLabels.inline,
            wavy: wavy,
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('读出当前 / 总时长，并提供前进后退动作', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);
      final node = tester.getSemantics(find.bySemanticsLabel('播放进度'));
      expect(node.label, '播放进度');
      expect(node.value, '0:00，共 3:00');
      expect(node.getSemanticsData().flagsCollection.isLiveRegion, isFalse);
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.increase),
        isTrue,
      );
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.decrease),
        isTrue,
      );

      tester.semantics.increase(find.semantics.byLabel('播放进度'));
      await tester.pump();
      expect(seeks, [10000]);

      tester.semantics.decrease(find.semantics.byLabel('播放进度'));
      await tester.pump();
      expect(seeks.last, 0);
      // 预览提交的兜底计时器：推进到它结束，避免测试收尾报 pending timer。
      await tester.pump(const Duration(seconds: 2));
      semantics.dispose();
    });

    testWidgets('减弱动效时波浪滑杆回落平直', (tester) async {
      await tester.pumpWidget(
        _app(
          SeekBar(
            controller: controller,
            position: position,
            durationMs: 180000,
            isPlaying: true,
            hasTrack: true,
            timeLabels: SeekTimeLabels.inline,
            wavy: true,
          ),
          disableAnimations: true,
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('seekBarFlat')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('seekBarWavy')), findsNothing);
    });

    testWidgets('系统减弱动态效果（reduceMotion）时波浪滑杆同样回落平直', (tester) async {
      await tester.pumpWidget(
        _app(
          SeekBar(
            controller: controller,
            position: position,
            durationMs: 180000,
            isPlaying: true,
            hasTrack: true,
            timeLabels: SeekTimeLabels.inline,
            wavy: true,
          ),
          reduceMotion: true,
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('seekBarFlat')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('seekBarWavy')), findsNothing);
    });
  });

  group('主链路语义', () {
    testWidgets('播放/暂停状态、封面、收藏与加入列表都可读', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final semantics = tester.ensureSemantics();
      await pumpPerfApp(
        tester,
        desktopShell: false,
        favoritesCount: 3,
        size: const Size(900, 900),
      );

      // 顶栏迷你播放器：正在播放时按钮读「暂停」，点后读「播放」。
      expect(find.bySemanticsLabel('暂停'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('暂停'));
      await tester.pump();
      expect(find.bySemanticsLabel('播放'), findsOneWidget);

      // 行尾动作菜单包含「加入列表」。
      await tester.tap(find.byType(RowActionMenuButton).first);
      await tester.pumpAndSettle();
      expect(find.text('加入列表'), findsOneWidget);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();

      // 播放页封面标注打开目标；收藏按钮读当前状态。
      await tester.tap(find.text('播放').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.bySemanticsLabel('打开播放页：Queue Track 0'), findsOneWidget);
      expect(find.bySemanticsLabel('收藏'), findsWidgets);
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('弹层焦点', () {
    testWidgets('关闭后焦点回到打开前的控件', (tester) async {
      final focusNode = FocusNode(debugLabel: 'sheetTrigger');
      addTearDown(focusNode.dispose);
      late BuildContext hostContext;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              hostContext = context;
              return Center(
                child: Focus(
                  focusNode: focusNode,
                  child: const SizedBox(width: 48, height: 48),
                ),
              );
            },
          ),
        ),
      );
      focusNode.requestFocus();
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);

      final opened = ResponsiveNavigation.showSimpleModal<void>(
        context: hostContext,
        title: '标题',
        child: const Text('内容'),
      );
      await tester.pumpAndSettle();
      expect(find.text('内容'), findsOneWidget);

      Navigator.of(hostContext).pop();
      await tester.pumpAndSettle();
      await opened;
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
    });
  });

  group('队列行语义', () {
    testWidgets('移动 / 移除动作与菜单边界一致', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repo = FakeLibraryRepository();
      final facade = FakePlaybackFacade();
      final playback = buildTestPlaybackProvider(
        facade: facade,
        libraryRepository: repo,
      );
      final library = LibraryProvider(
        repository: repo,
        playbackProvider: playback,
      );
      final controller = ScrollController();
      addTearDown(() {
        controller.dispose();
        library.dispose();
        playback.dispose();
      });
      final one = Track(
        id: const TrackId('kw', '1'),
        title: 'One',
        origin: TrackOrigin.builtin,
      );
      final two = Track(
        id: const TrackId('kw', '2'),
        title: 'Two',
        origin: TrackOrigin.builtin,
      );
      final three = Track(
        id: const TrackId('kw', '3'),
        title: 'Three',
        origin: TrackOrigin.builtin,
      );
      facade.emit(
        PlaybackSnapshot(
          current: one,
          queue: [one, two, three],
          currentIndex: 0,
          upNext: [two, three],
          upNextIndices: [1, 2],
        ),
      );
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            coverStoreProvider(),
            ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
            ChangeNotifierProvider<LibraryProvider>.value(value: library),
          ],
          child: _app(QueueDisplay(controller: controller)),
        ),
      );
      await tester.pump();

      List<String> actionsOf(String title) {
        final index = switch (title) {
          'Two' => 1,
          _ => 2,
        };
        final node = tester.getSemantics(
          find.byKey(ValueKey<String>('queueRowSemantics-$index')),
        );
        final ids =
            node.getSemanticsData().customSemanticsActionIds ?? const <int>[];
        return [
          for (final id in ids) ?CustomSemanticsAction.getAction(id)?.label,
        ]..sort();
      }

      expect(
        find.byKey(const ValueKey<String>('queueRowSemantics-0')),
        findsNothing,
        reason: '当前曲目行的动作菜单不含移动 / 移除，也不挂自定义动作',
      );
      expect(actionsOf('Two'), ['下移', '移出队列']);
      expect(actionsOf('Three'), ['上移', '下一首播放', '移出队列']);
      semantics.dispose();
    });
  });

  group('歌词行语义', () {
    testWidgets('当前行可识别，逐字歌词合并为一行文本', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final facade = FakePlaybackFacade();
      final playback = buildTestPlaybackProvider(facade: facade);
      final display = LyricsDisplaySettings(settings: testSettingsRegistry());
      final track = Track(
        id: const TrackId('kw', '1'),
        title: 'Song',
        duration: const Duration(minutes: 3),
        origin: TrackOrigin.builtin,
      );
      final lyrics = _FakeLyricsProvider(
        LyricsState(
          trackId: 'kw:1',
          status: LyricsStatus.ready,
          lines: const [
            LyricLine(Duration(seconds: 1), '第一行'),
            LyricLine(Duration(seconds: 30), '第二行'),
          ],
          isSynced: true,
        ),
      );
      facade.emit(
        PlaybackSnapshot(
          current: track,
          queue: [track],
          currentIndex: 0,
          isPlaying: true,
          duration: const Duration(minutes: 3),
        ),
        position: const Duration(seconds: 31),
      );
      addTearDown(() {
        playback.dispose();
        display.dispose();
        lyrics.dispose();
      });
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            coverStoreProvider(),
            ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
            ChangeNotifierProvider<LyricsProvider>.value(value: lyrics),
            ChangeNotifierProvider<LyricsDisplaySettings>.value(value: display),
          ],
          child: _app(const LyricsWidget()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      final current = tester.getSemantics(find.bySemanticsLabel('第二行'));
      expect(
        current.getSemanticsData().flagsCollection.isSelected ==
            Tristate.isTrue,
        isTrue,
      );
      final other = tester.getSemantics(find.bySemanticsLabel('第一行'));
      expect(
        other.getSemanticsData().flagsCollection.isSelected == Tristate.isTrue,
        isFalse,
      );
      semantics.dispose();
    });
  });
}
