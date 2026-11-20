import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/now_playing_summary.dart';
import 'package:molia/widgets/playback_transport.dart';
import 'package:molia/widgets/player.dart';
import 'package:molia/widgets/player_cover_deck.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cover_test_support.dart';
import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

/// 播放器版式与语义（`lib/widgets/player.dart`）：
/// - 桌面单栏播放页（无传输排）的音量入口；
/// - 350–399 迷你条只留三个传输键（标题列不再被挤成 72dp）；
/// - 播放页 / 迷你条 / 侧邻封面的读屏语义与光标；
/// - 大屏播放页的字号预算（200% 字号不把进度排顶出可视区）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLibraryRepository repository;
  late FakePlaybackFacade backend;
  late PlaybackProvider playback;
  late LibraryProvider library;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = FakeLibraryRepository();
    backend = FakePlaybackFacade();
    playback = buildTestPlaybackProvider(
      facade: backend,
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

  /// 平台判定是全局 debug 开关：必须在测试体内复位（框架在 tearDown 之前
  /// 校验「测试没有改动 foundation debug 变量」）。
  Future<void> withPlatform(
    TargetPlatform platform,
    Future<void> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Track track(String id, {String? title}) => Track(
    id: TrackId('wy', id),
    title: title ?? 'Song $id',
    artists: const [Artist(name: 'Artist')],
    origin: TrackOrigin.builtin,
  );

  /// 固定物理尺寸 + 字号缩放的宿主（`context.isNarrow` 读的是 MediaQuery）。
  Widget host(
    Widget child, {
    Size size = const Size(480, 640),
    double textScale = 1,
  }) {
    return MultiProvider(
      providers: [
        coverStoreProvider(),
        ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
        ChangeNotifierProvider<LibraryProvider>.value(value: library),
      ],
      child: M3EMaterialApp(
        data: M3EThemeData.fromMaterial(ThemeData.light()),
        theme: ThemeData.light(),
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: SizedBox(
              width: size.width,
              height: size.height,
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  void emitSingle(Track current) {
    backend.emit(
      PlaybackSnapshot(
        current: current,
        queue: [current],
        currentIndex: 0,
        isPlaying: true,
        duration: const Duration(minutes: 3),
      ),
    );
  }

  testWidgets('桌面单栏播放页 480 宽有音量入口，且进度条可拖宽足够', (tester) async {
    await withPlatform(TargetPlatform.linux, () async {
      emitSingle(track('1'));

      await tester.pumpWidget(host(const Player()));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(Player.volumeButtonKey), findsOneWidget);
      // 音量入口占用后进度条仍要留出可拖宽度（不是只剩滑杆两端）。
      expect(
        tester.getSize(find.byType(PlaybackSeekBar)).width,
        greaterThan(240),
      );

      await tester.tap(find.byKey(Player.volumeButtonKey));
      // 波浪进度条是无限动画，不能 pumpAndSettle；给面板弹簧足够帧。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(Player.volumePanelKey), findsOneWidget);
    });
  });

  testWidgets('移动端播放页不出现屏幕音量控件', (tester) async {
    await withPlatform(TargetPlatform.android, () async {
      emitSingle(track('1'));

      await tester.pumpWidget(host(const Player()));
      await tester.pump();

      expect(find.byKey(Player.volumeButtonKey), findsNothing);
    });
  });

  testWidgets('360 宽迷你条标题可用宽度大于 100dp，且只有三个传输键', (tester) async {
    const title = 'A very long song title for narrow windows';
    emitSingle(track('1', title: title));

    await tester.pumpWidget(
      host(
        // 0 = 收起态：完整层被 ExcludeSemantics / IgnorePointer 挂起，
        // 迷你条按 72dp 稳态渲染。
        const Player(expandAnimation: AlwaysStoppedAnimation<double>(0)),
        size: const Size(360, 400),
      ),
    );
    await tester.pump();

    final miniBar = find.byKey(Player.miniBarKey);
    expect(miniBar, findsOneWidget);

    final titleBox = tester.getSize(
      find.descendant(of: miniBar, matching: find.text(title)),
    );
    expect(titleBox.width, greaterThan(100));

    for (final type in const [
      PlaybackPreviousButton,
      PlaybackPlayPauseButton,
      PlaybackNextButton,
    ]) {
      expect(
        find.descendant(of: miniBar, matching: find.byType(type)),
        findsOneWidget,
        reason: '$type 应在迷你条里',
      );
    }
    expect(
      find.descendant(
        of: miniBar,
        matching: find.byType(NowPlayingFavoriteButton),
      ),
      findsNothing,
      reason: '窄档只留三个传输键，收藏在播放页进度排',
    );
  });

  testWidgets('播放页封面语义是播放/暂停，迷你条封面仍是打开播放页', (tester) async {
    final semantics = tester.ensureSemantics();
    final l10n = lookupAppLocalizations(const Locale('zh'));
    final current = track('1', title: 'Now Playing');
    emitSingle(current);

    // 完整播放页：封面点击是播放 / 暂停，不是「打开播放页」。
    await tester.pumpWidget(host(const Player()));
    await tester.pump();

    final pageLabel = '${l10n.pause} · ${current.title}';
    expect(find.bySemanticsLabel(pageLabel), findsOneWidget);
    expect(
      find.bySemanticsLabel(l10n.openPlayerFor(current.title)),
      findsNothing,
      reason: '播放页封面不打开播放页（已经在播放页里）',
    );
    final data = tester
        .getSemantics(find.byKey(PlayerCoverDeck.stackKey))
        .getSemanticsData();
    expect(data.flagsCollection.isButton, isTrue);
    // 标成按钮还不够：读屏用户要能执行动作，不能只听到「播放 / 暂停」。
    expect(
      data.hasAction(SemanticsAction.tap),
      isTrue,
      reason: '播放页封面语义节点必须提供 tap 动作',
    );

    // 收起态：迷你条封面点击整条即展开，语义保持「打开播放页」。
    await tester.pumpWidget(
      host(
        const Player(expandAnimation: AlwaysStoppedAnimation<double>(0)),
        size: const Size(360, 400),
      ),
    );
    await tester.pump();

    expect(
      find.bySemanticsLabel(l10n.openPlayerFor(current.title)),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(pageLabel), findsNothing);
    semantics.dispose();
  });

  testWidgets('侧邻封面有上一首/下一首语义与手型光标', (tester) async {
    final semantics = tester.ensureSemantics();
    final l10n = lookupAppLocalizations(const Locale('zh'));
    final previous = track('previous');
    final current = track('current');
    final next = track('next');
    backend.emit(
      PlaybackSnapshot(
        current: current,
        queue: [previous, current, next],
        currentIndex: 1,
        previous: previous,
        next: next,
        upNext: [next],
        upNextIndices: [2],
        duration: const Duration(minutes: 3),
      ),
    );

    await tester.pumpWidget(host(const Player()));
    await tester.pump();

    expect(find.bySemanticsLabel(l10n.previousTrackTooltip), findsOneWidget);
    expect(find.bySemanticsLabel(l10n.nextTrackTooltip), findsOneWidget);

    // 可点时才给手型光标（桌面鼠标用户能看出封面能点）。
    for (final key in [
      PlayerCoverDeck.sideCoverCardKey(left: true, id: previous.id),
      PlayerCoverDeck.sideCoverCardKey(left: false, id: next.id),
    ]) {
      final cursors = tester.widgetList<MouseRegion>(
        find.ancestor(of: find.byKey(key), matching: find.byType(MouseRegion)),
      );
      expect(
        cursors.any((region) => region.cursor == SystemMouseCursors.click),
        isTrue,
        reason: '可点击的侧邻封面应有手型光标',
      );
    }
    semantics.dispose();
  });

  testWidgets('480 宽桌面列 + 200% 字号不溢出，时间行留在播放器内', (tester) async {
    emitSingle(track('1'));

    await tester.pumpWidget(
      host(
        const Player(isLargeScreen: true, desktopLayout: true),
        size: const Size(480, 400),
        textScale: 2,
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    final playerBottom = tester.getRect(find.byType(Player)).bottom;
    for (final label in ['0:00', '3:00']) {
      expect(
        tester.getRect(find.text(label)).bottom,
        lessThanOrEqualTo(playerBottom),
        reason: '条下方的时间行「$label」被挤出播放器可视区',
      );
    }
  });
}
