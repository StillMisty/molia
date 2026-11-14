import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/ai_dj_page.dart';
import 'package:molia/providers/ai_dj_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/ai/ai_recommendation_store.dart';
import 'package:molia/services/ai/ai_settings_store.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cover_test_support.dart';
import '../support/fake_ai_generator.dart';
import '../support/fake_library_repository.dart';
import '../support/fakes.dart';
import '../support/settings_test_support.dart';

Track _track(int index) => Track(
  id: TrackId('wy', '$index'),
  title: 'Song $index',
  artists: const [Artist(name: 'Artist')],
  duration: const Duration(seconds: 100),
  origin: TrackOrigin.builtin,
);

AiDjBatch _batch() => AiDjBatch(
  items: [
    for (var i = 0; i < 3; i++)
      ResolvedRecommendation(
        source: AiRecommendation(title: 'Song $i', artist: 'Artist'),
        track: _track(i),
        sourceName: '网易云音乐',
      ),
  ],
  generatedAt: DateTime.now(),
);

/// AI 推歌页：页内唯一主操作是「播放全部」，低频动作收进顶栏溢出。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('播放全部是唯一 filled 主操作，换一批 / 补一批 / 历史在顶栏溢出', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final l10n = lookupAppLocalizations(const Locale('zh'));
    final secrets = MemorySettingsSecretStore();
    final backend = FakePlaybackFacade();
    final playback = buildTestPlaybackProvider(facade: backend);
    await playback.preferencesReady;
    final library = LibraryProvider(
      repository: FakeLibraryRepository(),
      playbackProvider: playback,
    );
    final prefs = await SharedPreferences.getInstance();
    final settings = testSettingsRegistry(preferences: prefs, secrets: secrets);
    await AiSettingsStore(settings: settings).saveConfig(
      const LlmConfig(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-test',
        model: 'm',
      ),
    );
    final ai = AiDjProvider(
      playbackProvider: playback,
      libraryProvider: library,
      recommendationService: FakeAiDjGenerator(batchFactory: _batch),
      settingsStore: AiSettingsStore(settings: settings),
      // 历史写文件走 path_provider：widget 测试没有插件，显式关掉文件后端
      // （退回 prefs），避免挂在永不完成的平台通道上。
      recommendationStore: AiRecommendationStore(
        preferences: prefs,
        directoryProvider: () async => null,
      ),
    );
    await ai.init();
    await ai.grantConsent();
    await ai.setEnabled(true);
    addTearDown(() {
      ai.dispose();
      library.dispose();
      playback.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          coverStoreProvider(),
          ChangeNotifierProvider<AiDjProvider>.value(value: ai),
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
          home: const AiDjPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 页内只有一个 filled 主操作（播放全部）；加入队列保持 tonal。
    expect(
      tester
          .widget<M3EButton>(find.byKey(const Key('aiDjPlayAllButton')))
          .style,
      M3EButtonStyle.filled,
    );
    expect(
      tester
          .widget<M3EButton>(find.byKey(const Key('aiDjEnqueueAllButton')))
          .style,
      M3EButtonStyle.tonal,
    );
    // 分区标题行不再有换一批 / 补一批图标按钮。
    expect(find.byKey(const Key('aiDjRefreshBatchButton')), findsNothing);
    expect(find.byKey(const Key('aiDjFeedBatchButton')), findsNothing);

    // 顶栏只有一个溢出入口，三个低频动作都在里面。
    expect(find.byKey(const Key('aiDjHistoryButton')), findsNothing);
    await tester.tap(find.byKey(const Key('aiDjMoreButton')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiDjRefreshBatch), findsOneWidget);
    expect(find.text(l10n.aiDjFeedBatch), findsOneWidget);
    expect(find.text(l10n.aiDjHistoryTitle), findsOneWidget);
  });
}
