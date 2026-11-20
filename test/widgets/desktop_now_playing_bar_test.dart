import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/desktop/now_playing_bar.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/domain/models/play_mode.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/now_playing_summary.dart';
import 'package:molia/widgets/playback_transport.dart';
import 'package:molia/widgets/player_morph.dart';
import 'package:molia/widgets/volume_control.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cover_test_support.dart';
import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

/// 桌面底栏：播放模式 + 音量 + 队列（ADR-0030，与播放页进度排同源）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('底栏有播放模式按钮，音量与队列入口保留', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final backend = FakePlaybackFacade();
    final playback = buildTestPlaybackProvider(facade: backend);
    final morph = PlayerMorphController();
    addTearDown(() {
      morph.dispose();
      playback.dispose();
    });
    final track = Track(
      id: const TrackId('wy', '1'),
      title: 'Song',
      origin: TrackOrigin.builtin,
    );
    backend.emit(
      PlaybackSnapshot(current: track, queue: [track], currentIndex: 0),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          coverStoreProvider(),
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
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
          home: Scaffold(
            body: DesktopNowPlayingBar(
              morph: morph,
              onOpenPlayer: () {},
              onOpenQueue: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final bar = find.byType(DesktopNowPlayingBar);
    expect(bar, findsOneWidget);
    expect(
      find.descendant(of: bar, matching: find.byType(PlaybackModeButton)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bar, matching: find.byIcon(Icons.repeat_rounded)),
      findsOneWidget,
      reason: '默认 listLoop 图标常显',
    );
    await tester.tap(
      find.descendant(of: bar, matching: find.byType(PlaybackModeButton)),
    );
    await tester.pumpAndSettle();
    expect(playback.currentMode, PlayMode.sequential);
    expect(
      find.descendant(of: bar, matching: find.byType(VolumeControl)),
      findsOneWidget,
    );
    expect(find.byKey(DesktopNowPlayingBar.openQueueKey), findsOneWidget);
  });

  /// 在指定窗口宽下挂载底栏（带资料库，收藏按钮才会真正占位）。
  Future<void> pumpBarAt(
    WidgetTester tester,
    Size size, {
    required String title,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final repository = FakeLibraryRepository();
    addTearDown(repository.dispose);
    final backend = FakePlaybackFacade();
    final playback = buildTestPlaybackProvider(
      facade: backend,
      libraryRepository: repository,
    );
    final library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    addTearDown(() {
      library.dispose();
      playback.dispose();
    });
    final morph = PlayerMorphController();
    addTearDown(morph.dispose);

    final track = Track(
      id: const TrackId('wy', '1'),
      title: title,
      artists: const [Artist(name: 'Artist')],
      origin: TrackOrigin.builtin,
    );
    backend.emit(
      PlaybackSnapshot(current: track, queue: [track], currentIndex: 0),
    );

    await tester.pumpWidget(
      MultiProvider(
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
          home: Scaffold(
            body: DesktopNowPlayingBar(
              morph: morph,
              onOpenPlayer: () {},
              onOpenQueue: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('720 宽：标题区 ≥140dp，收藏在右区动作组', (tester) async {
    const title = 'A long desktop now playing bar title';
    await pumpBarAt(tester, const Size(720, 600), title: title);

    final bar = find.byType(DesktopNowPlayingBar);
    final titleWidth = tester.getSize(find.text(title)).width;
    expect(
      titleWidth,
      greaterThanOrEqualTo(140),
      reason: '720 宽下标题区不能被中区 / 动作组挤到 140dp 以下',
    );

    // 收藏是播放动作：从摘要尾部移到右区动作组（不再属于左区摘要）。
    final favorite = find.descendant(
      of: bar,
      matching: find.byType(NowPlayingFavoriteButton),
    );
    expect(favorite, findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(NowPlayingSummary),
        matching: find.byType(NowPlayingFavoriteButton),
      ),
      findsNothing,
    );

    final seekRect = tester.getRect(
      find.descendant(of: bar, matching: find.byType(PlaybackSeekBar)),
    );
    expect(
      tester.getTopLeft(favorite).dx,
      greaterThan(seekRect.center.dx),
      reason: '收藏应位于中区右侧的动作组里',
    );
    // 720 是 80dp 底栏的起点：固定动作已占 336dp，进度排只剩一百多；
    // 至少锁住「还能拖」的下限，避免以后再往动作组塞按钮把它吃光。
    expect(
      seekRect.width,
      greaterThanOrEqualTo(120),
      reason: '720 宽下进度排仍要留出可拖宽度',
    );
  });

  testWidgets('1280 宽：中区封顶 520dp，进度条不被压缩', (tester) async {
    const title = 'A long desktop now playing bar title';
    await pumpBarAt(tester, const Size(1280, 600), title: title);

    final bar = find.byType(DesktopNowPlayingBar);
    final previousRect = tester.getRect(
      find.descendant(of: bar, matching: find.byType(PlaybackPreviousButton)),
    );
    final seekRect = tester.getRect(
      find.descendant(of: bar, matching: find.byType(PlaybackSeekBar)),
    );
    final centerWidth = seekRect.right - previousRect.left;
    expect(centerWidth, lessThanOrEqualTo(520), reason: '宽屏把中区余量还给左区标题');
    expect(seekRect.width, greaterThan(280), reason: '1280 宽下进度条仍有足够可拖宽度');
    expect(tester.getSize(find.text(title)).width, greaterThanOrEqualTo(140));
  });
}
