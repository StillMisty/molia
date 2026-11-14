import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/widgets/lyrics.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cover_test_support.dart';
import '../support/fakes.dart';
import '../support/settings_test_support.dart';

class _FakeLyricsProvider extends LyricsProvider {
  _FakeLyricsProvider(this._state);

  final LyricsState _state;

  @override
  LyricsState get state => _state;
}

/// 歌词 FAB：前四项固定为 换源 / 复制歌词 / 歌词海报 / 显示设置，
/// 「居中当前行」只能作为第五项追加（不改变前四项）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FAB 动作序列', () {
    test('前四项恒定，居中当前行只在手动滚动后追加', () {
      const fixed = [
        LyricsQuickAction.swapSource,
        LyricsQuickAction.copyLyrics,
        LyricsQuickAction.poster,
        LyricsQuickAction.displaySettings,
      ];
      expect(
        lyricsQuickActionOrder(
          hasLyrics: true,
          synced: true,
          autoScroll: false,
        ),
        [...fixed, LyricsQuickAction.centerCurrentLine],
      );
      expect(
        lyricsQuickActionOrder(hasLyrics: true, synced: true, autoScroll: true),
        fixed,
      );
      expect(
        lyricsQuickActionOrder(
          hasLyrics: false,
          synced: false,
          autoScroll: true,
        ),
        fixed,
      );
    });
  });

  group('FAB 文案', () {
    testWidgets('无歌词也显示固定四项，顺序与文案一致', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final l10n = lookupAppLocalizations(const Locale('zh'));
      final facade = FakePlaybackFacade();
      final playback = buildTestPlaybackProvider(facade: facade);
      final display = LyricsDisplaySettings(settings: testSettingsRegistry());
      final lyrics = _FakeLyricsProvider(
        const LyricsState(trackId: 'kw:1', status: LyricsStatus.ready),
      );
      final track = Track(
        id: const TrackId('kw', '1'),
        title: 'Song',
        duration: const Duration(minutes: 3),
        origin: TrackOrigin.builtin,
      );
      facade.emit(
        PlaybackSnapshot(
          current: track,
          queue: [track],
          currentIndex: 0,
          isPlaying: true,
          duration: const Duration(minutes: 3),
        ),
      );
      addTearDown(() {
        playback.dispose();
        display.dispose();
        lyrics.dispose();
      });

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            coverStoreProvider(),
            ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
            ChangeNotifierProvider<LyricsProvider>.value(value: lyrics),
            ChangeNotifierProvider<LyricsDisplaySettings>.value(value: display),
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
            home: const Scaffold(body: LyricsWidget()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.byKey(const Key('lyricsQuickActions')));
      await tester.pumpAndSettle();

      expect(find.text(l10n.lyricsSwapAction), findsOneWidget);
      expect(find.text(l10n.lyricsCopyModeAction), findsOneWidget);
      expect(find.text(l10n.lyricsPosterAction), findsOneWidget);
      expect(find.text(l10n.lyricsDisplaySettingsAction), findsOneWidget);
      expect(find.text(l10n.centerCurrentLine), findsNothing);
      expect(
        [l10n.lyricsSwapAction, l10n.lyricsCopyModeAction],
        ['换源', '复制歌词'],
        reason: '文案与「换源」页 / 复制动作对齐',
      );
    });
  });
}
