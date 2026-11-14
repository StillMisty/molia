import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/player.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cover_test_support.dart';
import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

/// 播放器「更多」菜单：播放模式 / 存为列表 / 歌词显示设置。
///
/// 播放模式不再常显（进度排只留收藏 + 进度 + 更多），因此这里同时锁住
/// 「可见模式按钮消失」和「模式仍可达」两条不变量。
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

  testWidgets('进度排只保留更多入口，菜单含播放模式 / 存为列表 / 歌词显示设置', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    final first = track('1');
    backend.emit(
      PlaybackSnapshot(current: first, queue: [first], currentIndex: 0),
    );
    await tester.pumpWidget(host(const Player()));
    await tester.pump();

    // 播放模式不再常显：进度排里只有「更多」这一个菜单入口。
    for (final icon in const [
      Icons.shuffle_rounded,
      Icons.repeat_rounded,
      Icons.repeat_one_rounded,
      Icons.playlist_play_rounded,
    ]) {
      expect(find.byIcon(icon), findsNothing, reason: '$icon 不应常显');
    }
    expect(find.byKey(const Key('playerMoreButton')), findsOneWidget);

    await tester.tap(find.byKey(const Key('playerMoreButton')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.playModeTitle), findsOneWidget);
    expect(find.text(l10n.queueSaveAsPlaylist), findsOneWidget);
    expect(find.text(l10n.lyricsDisplaySettingsAction), findsOneWidget);
  });

  testWidgets('更多 › 播放模式：子菜单仍可切换模式', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    final first = track('1');
    backend.emit(
      PlaybackSnapshot(current: first, queue: [first], currentIndex: 0),
    );
    await tester.pumpWidget(host(const Player()));
    await tester.pump();

    await tester.tap(find.byKey(const Key('playerMoreButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.playModeTitle));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.playModeSingleRepeat));
    await tester.pumpAndSettle();

    expect(playback.currentMode, PlayMode.singleRepeat);
  });

  testWidgets('更多 › 存为列表：一次新建 + 批量加入，重复项合并', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    final first = track('1');
    final second = track('2');
    backend.emit(
      PlaybackSnapshot(
        current: first,
        queue: [first, first, second],
        currentIndex: 0,
      ),
    );
    await tester.pumpWidget(host(const Player()));
    await tester.pump();

    await tester.tap(find.byKey(const Key('playerMoreButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.queueSaveAsPlaylist));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, '队列 A');
    await tester.tap(find.text(l10n.playlistCreateConfirm));
    await tester.pumpAndSettle();

    final saved = await repository.findPlaylistByName('队列 A');
    expect(saved, isNotNull);
    expect((await repository.listPlaylistTracks(saved!.id)).length, 2);
    expect(
      find.textContaining(l10n.queueSavedAsPlaylist('队列 A', 2, 1)),
      findsOneWidget,
    );
  });

  testWidgets('更多 › 存为列表：批量加入失败删除新列表', (tester) async {
    repository.failTrackWrites = true;
    final l10n = lookupAppLocalizations(const Locale('zh'));
    final first = track('1');
    backend.emit(
      PlaybackSnapshot(current: first, queue: [first], currentIndex: 0),
    );
    await tester.pumpWidget(host(const Player()));
    await tester.pump();

    await tester.tap(find.byKey(const Key('playerMoreButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.queueSaveAsPlaylist));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, '失败队列');
    await tester.tap(find.text(l10n.playlistCreateConfirm));
    await tester.pumpAndSettle();

    expect(await repository.findPlaylistByName('失败队列'), isNull);
    expect(find.text(l10n.queueSaveFailed), findsOneWidget);
  });
}
