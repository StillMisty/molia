import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/desktop/now_playing_bar.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/playback_transport.dart';
import 'package:molia/widgets/player_morph.dart';
import 'package:molia/widgets/volume_control.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cover_test_support.dart';
import '../support/fakes.dart';

/// 桌面底栏：播放模式是播放页「更多」的职责，底栏不再重复。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('底栏不再有播放模式按钮，音量与队列入口保留', (tester) async {
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
      findsNothing,
    );
    expect(
      find.descendant(of: bar, matching: find.byType(VolumeControl)),
      findsOneWidget,
    );
    expect(find.byKey(DesktopNowPlayingBar.openQueueKey), findsOneWidget);
  });
}
