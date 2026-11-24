import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/ai_dj_history_page.dart';
import 'package:molia/providers/ai_dj_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/services/ai/ai_recommendation_store.dart';
import 'package:molia/services/ai/ai_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/ai_dj_test_support.dart';
import '../support/fake_ai_generator.dart';
import '../support/fake_library_repository.dart';
import '../support/fakes.dart';
import '../support/provider_test_scope.dart';
import '../support/settings_test_support.dart';

Track _track(int index) => Track(
  id: TrackId('wy', '$index'),
  title: 'Song $index',
  artists: const [Artist(name: 'Artist')],
  duration: const Duration(seconds: 100),
  origin: TrackOrigin.builtin,
);

AiDjBatch _batch(int from) => AiDjBatch(
  items: [
    for (var i = 0; i < 3; i++)
      ResolvedRecommendation(
        source: AiRecommendation(title: 'Song ${from + i}', artist: 'Artist'),
        track: _track(from + i),
        sourceName: '网易音乐',
      ),
  ],
  generatedAt: DateTime.now(),
);

/// 带历史索引 / 待恢复批次的测试环境。
typedef _HistoryHarness = ({AiDjProvider ai, FakePlaybackFacade backend});

Future<_HistoryHarness> _pumpHistory(
  WidgetTester tester, {
  int batches = 2,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final settings = testSettingsRegistry(preferences: prefs);
  await AiSettingsStore(settings: settings).saveConfig(
    const LlmConfig(
      baseUrl: 'https://api.example.com/v1',
      apiKey: 'sk-test',
      model: 'm',
    ),
  );
  final backend = FakePlaybackFacade();
  final playback = buildTestPlaybackProvider(facade: backend);
  await playback.preferencesReady;
  final library = LibraryProvider(
    repository: FakeLibraryRepository(),
    playbackProvider: playback,
  );
  final generator = FakeAiDjGenerator(batchFactory: () => _batch(0));
  final ai = AiDjProvider(
    playbackProvider: playback,
    libraryProvider: library,
    recommendationService: generator,
    settingsStore: AiSettingsStore(settings: settings),
    recommendationStore: testAiRecommendationStore(preferences: prefs),
  );
  await ai.init();
  await ai.grantConsent();
  await ai.setEnabled(true);
  for (var i = 1; i < batches; i++) {
    generator.batchFactory = () => _batch(i * 10);
    await ai.refreshRecommendations();
  }
  addTearDown(() {
    ai.dispose();
    library.dispose();
    playback.dispose();
  });

  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final scope = ProviderTestScope()..put<AiDjProvider>(ai);
  await tester.pumpWidget(
    scope.wrap(
      M3EMaterialApp(
        data: M3EThemeData.fromMaterial(ThemeData.light()),
        theme: ThemeData.light(),
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        home: const AiDjHistoryPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (ai: ai, backend: backend);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('展开后点第 i 首，从第 i 首起播而不是批次第一首', (tester) async {
    final harness = await _pumpHistory(tester);
    final ai = harness.ai;
    final batchId = ai.state.activeBatchId!;

    await tester.tap(find.byKey(Key('aiDjHistoryExpand_$batchId')));
    await tester.pumpAndSettle();
    expect(find.text('Song 12'), findsOneWidget);

    await tester.tap(find.text('Song 12'));
    await tester.pumpAndSettle();

    expect(harness.backend.lastRequest?.startIndex, 2);
    expect(
      harness.backend.lastRequest?.tracks.map((track) => track.title).toList(),
      ['Song 10', 'Song 11', 'Song 12'],
      reason: '只改起点，批次顺序与整批接管语义不变',
    );
    expect(ai.state.activeBatchId, batchId);
  });

  testWidgets('删除整批先确认；取消后批次仍在，确认后移除', (tester) async {
    final harness = await _pumpHistory(tester);
    final ai = harness.ai;
    final olderId = ai.state.historyEntries
        .firstWhere((entry) => entry.id != ai.state.activeBatchId)
        .id;

    await tester.tap(find.byKey(Key('aiDjHistoryDelete_$olderId')));
    await tester.pumpAndSettle();
    expect(find.text('删除这批推荐'), findsOneWidget);
    expect(find.textContaining('不可恢复'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(ai.state.historyEntries, hasLength(2), reason: '取消不删除');

    await tester.tap(find.byKey(Key('aiDjHistoryDelete_$olderId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('aiDjHistoryDeleteConfirm_$olderId')));
    await tester.pumpAndSettle();

    expect(ai.state.historyEntries, hasLength(1));
    expect(find.byKey(Key('aiDjHistoryEntry_$olderId')), findsNothing);
  });

  testWidgets('展开加载失败可重试，且只重新读取该批', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final brokenId = 'broken-batch';
    final entry = AiDjHistoryEntry(
      id: brokenId,
      generatedAt: DateTime(2026, 1, 1),
      itemCount: 2,
      unresolvedCount: 0,
      origin: AiDjOrigin.refresh,
    );
    await prefs.setString(
      AiRecommendationStore.indexKey,
      jsonEncode({
        'activeBatchId': null,
        'entries': [entry.toJson()],
      }),
    );

    final backend = FakePlaybackFacade();
    final playback = buildTestPlaybackProvider(facade: backend);
    await playback.preferencesReady;
    final library = LibraryProvider(
      repository: FakeLibraryRepository(),
      playbackProvider: playback,
    );
    final ai = AiDjProvider(
      playbackProvider: playback,
      libraryProvider: library,
      recommendationService: FakeAiDjGenerator(),
      settingsStore: AiSettingsStore(
        settings: testSettingsRegistry(preferences: prefs),
      ),
      recommendationStore: testAiRecommendationStore(preferences: prefs),
    );
    await ai.init();
    addTearDown(() {
      ai.dispose();
      library.dispose();
      playback.dispose();
    });

    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scope = ProviderTestScope()..put<AiDjProvider>(ai);
    await tester.pumpWidget(
      scope.wrap(
        M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData.light()),
          theme: ThemeData.light(),
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: const AiDjHistoryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('aiDjHistoryExpand_$brokenId')));
    await tester.pumpAndSettle();
    expect(find.text('这批内容已损坏，无法查看'), findsOneWidget);
    expect(find.byKey(Key('aiDjHistoryRetry_$brokenId')), findsOneWidget);

    // 载荷恢复后重试：只重读这一批，不触发生成。
    final stored = StoredAiBatch(
      id: brokenId,
      items: [
        const StoredAiBatchItem(
          sourceKey: 'wy',
          songId: '0',
          title: 'Recovered',
          artist: 'Artist',
          album: '',
          reason: 'reason',
        ),
      ],
      unresolved: const [],
      generatedAt: entry.generatedAt,
      origin: AiDjOrigin.refresh,
    );
    await prefs.setString(
      '${AiRecommendationStore.batchKeyPrefix}$brokenId',
      jsonEncode(stored.toJson()),
    );

    await tester.tap(find.byKey(Key('aiDjHistoryRetry_$brokenId')));
    await tester.pumpAndSettle();

    expect(find.text('Recovered'), findsOneWidget);
    expect(find.text('这批内容已损坏，无法查看'), findsNothing);
  });
}
