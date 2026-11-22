import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/domain/models/play_mode.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/playback_transport.dart';
import 'package:molia/widgets/player.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cover_test_support.dart';
import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

/// 播放页进度排的播放模式按钮（ADR-0030）。
///
/// 进度排不再有「更多」菜单：模式常显，点按按 [PlayMode.next] 循环，
/// 图标 / 语义标签走 `PlayModeTransportPresentation` 的唯一映射。
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

  Widget host(Widget child) {
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
        home: Scaffold(body: SizedBox(width: 400, height: 640, child: child)),
      ),
    );
  }

  Track track(String id) => Track(
    id: TrackId('wy', id),
    title: 'Song $id',
    origin: TrackOrigin.builtin,
  );

  testWidgets('进度排常显播放模式，不再有「更多」菜单', (tester) async {
    final first = track('1');
    backend.emit(
      PlaybackSnapshot(current: first, queue: [first], currentIndex: 0),
    );
    await tester.pumpWidget(host(const Player()));
    await tester.pump();

    expect(find.byType(PlaybackModeButton), findsOneWidget);
    expect(find.byKey(const Key('playerMoreButton')), findsNothing);
    expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
    // 默认 listLoop：进度排右侧直接显示循环图标。
    expect(find.byIcon(Icons.repeat_rounded), findsOneWidget);
  });

  testWidgets('点按按 PlayMode.next 循环，图标与语义标签同步', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    final semantics = tester.ensureSemantics();
    final first = track('1');
    backend.emit(
      PlaybackSnapshot(current: first, queue: [first], currentIndex: 0),
    );
    await tester.pumpWidget(host(const Player()));
    await tester.pump();

    expect(playback.currentMode, PlayMode.listLoop);
    expect(find.bySemanticsLabel(l10n.playModeListLoop), findsOneWidget);

    const expected = [
      (PlayMode.sequential, Icons.playlist_play_rounded),
      (PlayMode.singleRepeat, Icons.repeat_one_rounded),
      (PlayMode.shuffle, Icons.shuffle_rounded),
      (PlayMode.listLoop, Icons.repeat_rounded),
    ];
    for (final (mode, icon) in expected) {
      await tester.tap(find.byType(PlaybackModeButton));
      await tester.pumpAndSettle();
      expect(playback.currentMode, mode);
      expect(find.byIcon(icon), findsOneWidget, reason: '$mode 的图标');
      expect(
        find.bySemanticsLabel(switch (mode) {
          PlayMode.listLoop => l10n.playModeListLoop,
          PlayMode.sequential => l10n.playModeSequential,
          PlayMode.singleRepeat => l10n.playModeSingleRepeat,
          PlayMode.shuffle => l10n.playModeShuffle,
        }),
        findsOneWidget,
        reason: '$mode 的语义标签',
      );
    }
    semantics.dispose();
  });
}
