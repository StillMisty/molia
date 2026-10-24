import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/models/lyric_line.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/lyrics_selection_page.dart';

import '../support/fakes.dart';

/// 歌词选择页的当前行高亮：与播放页共用同一时间策略（200ms 视觉提前量）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playback;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
  });

  tearDown(() => playback.dispose());

  final track = Track(
    id: const TrackId('fake', 'selection'),
    title: 'Title',
    artists: const [Artist(name: 'Artist')],
    duration: const Duration(minutes: 5),
    origin: TrackOrigin.lx,
    payload: const {'id': 'selection'},
  );

  BackendSnapshot snapshot(Duration position) => BackendSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
        position: position,
        duration: const Duration(minutes: 5),
      );

  Future<void> pumpSelection(
    WidgetTester tester, {
    required List<LyricLine> lyrics,
    required Duration position,
    bool isSynced = true,
  }) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    backend.emit(snapshot(position));
    final themedData = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<PlaybackProvider>.value(
        value: playback,
        child: M3EMaterialApp(
          data: M3EThemeData.fromMaterial(themedData),
          theme: themedData,
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(
            body: LyricsSelectionPage(
              lyrics: lyrics,
              isSynced: isSynced,
              trackTitle: track.title,
              artistName: 'Artist',
              embedded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Color lineColor(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style!.color!;

  Color primaryOf(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(LyricsSelectionPage)))
          .colorScheme
          .primary;

  testWidgets('选择页与播放页同一 200ms 提前量：64.799s / 64.800s 边界', (tester) async {
    const lyrics = [
      LyricLine(Duration(seconds: 60), 'Line 60'),
      LyricLine(Duration(seconds: 65), 'Line 65'),
    ];

    await pumpSelection(
      tester,
      lyrics: lyrics,
      position: const Duration(milliseconds: 64799),
    );
    expect(
      lineColor(tester, 'Line 60'),
      primaryOf(tester),
      reason: '64.799s + 200ms 仍早于 65s，当前行应是 Line 60',
    );
    expect(lineColor(tester, 'Line 65'), isNot(primaryOf(tester)));

    // 64.800s + 200ms = 65.000s：到达 65s，与播放页同时切到 Line 65。
    // 位置通道对同曲目 <250ms 的变化不补发（≤4Hz），边界步进走显式 seek。
    await playback.seekToPosition(64800);
    await tester.pump();

    expect(
      lineColor(tester, 'Line 65'),
      primaryOf(tester),
      reason: '64.800s + 200ms 到达 65s，与播放页同时切到 Line 65',
    );
    expect(lineColor(tester, 'Line 60'), isNot(primaryOf(tester)));
  });

  testWidgets('未同步歌词不点亮任何行（不落到最后一行）', (tester) async {
    final unsynced = buildUnsyncedLyrics('第一行\n第二行');
    await pumpSelection(
      tester,
      lyrics: unsynced,
      position: const Duration(seconds: 30),
      isSynced: false,
    );

    expect(lineColor(tester, '第一行'), isNot(primaryOf(tester)));
    expect(lineColor(tester, '第二行'), isNot(primaryOf(tester)));
  });
}
