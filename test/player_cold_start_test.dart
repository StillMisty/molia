import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/nowplaying.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:molia/widgets/player_cover_deck.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/settings_test_support.dart';

/// 冷启动恢复态：播放页首帧的封面堆叠必须已经按队列（上一首 / 当前 /
/// 下一首）稳定就位，而不是把「挂载时已有的当前曲目」当成一次切歌、
/// 先播入场再落位。
Track _track(String id) => Track(
      id: TrackId('fake', id),
      title: 'Title $id',
      artists: [Artist(name: 'Artist $id')],
      album: 'Album',
      duration: const Duration(seconds: 30),
      origin: TrackOrigin.lx,
      payload: {'id': id},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Track a;
  late Track b;
  late Track c;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    a = _track('a');
    b = _track('b');
    c = _track('c');
    await PlaybackSessionStore().save(PlaybackSession(
      tracks: [a, b, c],
      index: 1,
      position: const Duration(seconds: 5),
    ));
  });

  Future<PlaybackProvider> restoredProvider(WidgetTester tester) async {
    // 假后端保持空：快照来自保存会话，模拟冷启动恢复（没有真实播放）。
    final playback = buildTestPlaybackProvider(backend: FakePlaybackBackend());
    addTearDown(playback.dispose);
    await playback.preferencesReady;
    expect(playback.snapshot.current?.id, b.id, reason: '恢复会话已装载');
    return playback;
  }

  Future<void> pumpNowPlaying(
    WidgetTester tester,
    PlaybackProvider playback, {
    bool startupReveal = false,
  }) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          // 空提供者列表：本测试只关心首帧封面，不触发歌词网络兜底。
          ChangeNotifierProvider(
            create: (_) =>
                LyricsProvider(service: LyricsService(providers: [])),
          ),
          ChangeNotifierProvider(
            create: (_) =>
                LyricsDisplaySettings(settings: testSettingsRegistry()),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: NowPlaying(startupReveal: startupReveal),
        ),
      ),
    );
    // 首帧：deck 绑定即接管初始身份，不等入场弹簧落位。
    await tester.pump();
  }

  void expectSteadyDeck(WidgetTester tester) {
    final deckCenter =
        tester.getCenter(find.byKey(PlayerCoverDeck.swipeHostKey));
    final coverCenter =
        tester.getCenter(find.byKey(PlayerCoverDeck.centerCoverCardKey));
    expect(
      (coverCenter.dx - deckCenter.dx).abs(),
      lessThan(0.5),
      reason: '首帧中心封面就在中心槽位（不是从侧槽进场）',
    );
    expect(
      find.byKey(PlayerCoverDeck.centerCoverTrackKey(b.id)),
      findsOneWidget,
      reason: '中心展示恢复的当前曲目',
    );
    expect(
      find.byKey(PlayerCoverDeck.sideCoverCardKey(left: true, id: a.id)),
      findsOneWidget,
      reason: '左槽首帧就是队列里的上一首',
    );
    expect(
      find.byKey(PlayerCoverDeck.sideCoverCardKey(left: false, id: c.id)),
      findsOneWidget,
      reason: '右槽首帧就是队列里的下一首',
    );
    expect(
      find.byKey(PlayerCoverDeck.outgoingCoverCardKey),
      findsNothing,
      reason: '首帧没有滑出卡（不是一次切歌）',
    );
  }

  testWidgets('首帧：中心已就位，左右邻位按恢复队列渲染', (tester) async {
    final playback = await restoredProvider(tester);
    await pumpNowPlaying(tester, playback);

    expectSteadyDeck(tester);
    final coverCenter =
        tester.getCenter(find.byKey(PlayerCoverDeck.centerCoverCardKey));

    await tester.pump(const Duration(milliseconds: 50));
    expect(
      tester.getCenter(find.byKey(PlayerCoverDeck.centerCoverCardKey)).dx,
      closeTo(coverCenter.dx, 0.5),
      reason: '首帧之后也不补播入场位移',
    );
  });

  testWidgets('启动首屏入场：封面首帧仍按队列稳态', (tester) async {
    final playback = await restoredProvider(tester);
    await pumpNowPlaying(tester, playback, startupReveal: true);

    // 首屏入场只播标题；整页不做透明度，封面堆叠也不参与。
    expectSteadyDeck(tester);
  });
}
