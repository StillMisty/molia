import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/ai_dj_history_page.dart';
import 'package:molia/providers/ai_dj_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/ai/ai_settings_store.dart';

import '../support/fake_ai_generator.dart';
import '../support/fake_library_repository.dart';
import '../support/fakes.dart';
import '../support/settings_test_support.dart';

AiDjBatch _batch(int from, int count) => AiDjBatch(
      items: [
        for (var i = 0; i < count; i++)
          ResolvedRecommendation(
            source: AiRecommendation(
              title: 'Song ${from + i}',
              artist: 'Artist',
              reason: 'reason ${from + i}',
            ),
            track: Track(
              id: TrackId('wy', '${from + i}'),
              title: 'Song ${from + i}',
              artists: const [Artist(name: 'Artist')],
              duration: const Duration(seconds: 100),
              origin: TrackOrigin.builtin,
            ),
            sourceName: '网易云音乐',
          ),
      ],
      unresolved: const [AiRecommendation(title: 'Ghost', artist: 'X')],
      generatedAt: DateTime.now(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playbackProvider;
  late LibraryProvider libraryProvider;
  late FakeAiDjGenerator generator;
  late MemorySettingsSecretStore secrets;
  late AiDjProvider provider;

  Future<void> pumpProvider() async {
    final prefs = await SharedPreferences.getInstance();
    await AiSettingsStore(
            settings:
                testSettingsRegistry(preferences: prefs, secrets: secrets))
        .saveConfig(const LlmConfig(
      baseUrl: 'https://api.example.com/v1',
      apiKey: 'sk-test',
      model: 'm',
    ));
    provider = AiDjProvider(
      playbackProvider: playbackProvider,
      libraryProvider: libraryProvider,
      recommendationService: generator,
      settingsStore: AiSettingsStore(
          settings: testSettingsRegistry(preferences: prefs, secrets: secrets)),
    );
    await provider.init();
  }

  Future<void> pumpHistory(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AiDjProvider>.value(value: provider),
          ChangeNotifierProvider<PlaybackProvider>.value(
              value: playbackProvider),
          ChangeNotifierProvider<LibraryProvider>.value(value: libraryProvider),
        ],
        child: M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData()),
          theme: ThemeData(),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('en'), Locale('zh')],
          home: const AiDjHistoryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> createTwoBatches() async {
    await provider.grantConsent();
    await provider.setEnabled(true);
    generator.batchFactory = () => _batch(10, 3);
    await provider.refreshRecommendations();
  }

  Future<void> pumpWithBatches(WidgetTester tester) async {
    await pumpHistory(tester);
    await tester.runAsync(createTwoBatches);
    await tester.pumpAndSettle();
  }

  /// 页面动作是 unawaited 的 provider 调用：让真实异步（存储 / 播放）收尾。
  Future<void> settleAction(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
  }

  Finder card(String id) => find.byKey(Key('aiDjHistoryEntry_$id'));
  Finder action(String id, String label) =>
      find.descendant(of: card(id), matching: find.text(label)).hitTestable();

  /// 可见动作直接点；被收进溢出菜单的动作先展开菜单。
  Future<void> tapAction(
    WidgetTester tester,
    String id,
    String label,
  ) async {
    var target = action(id, label);
    if (target.evaluate().isEmpty) {
      final overflow = find.descendant(
        of: card(id),
        matching: find.byIcon(Icons.more_horiz_rounded),
      );
      expect(overflow, findsOneWidget);
      await tester.tap(overflow);
      await tester.pumpAndSettle();
      target = find.text(label).hitTestable();
    }
    expect(target, findsOneWidget);
    await tester.tap(target);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secrets = MemorySettingsSecretStore();
    backend = FakePlaybackBackend();
    playbackProvider = buildTestPlaybackProvider(backend: backend);
    await playbackProvider.preferencesReady;
    libraryProvider = LibraryProvider(
      repository: FakeLibraryRepository(),
      playbackProvider: playbackProvider,
    );
    generator = FakeAiDjGenerator(batchFactory: () => _batch(0, 3));
    await pumpProvider();
  });

  tearDown(() {
    provider.dispose();
    libraryProvider.dispose();
    playbackProvider.dispose();
  });

  testWidgets('空态：还没有历史推荐', (tester) async {
    await pumpHistory(tester);

    expect(find.text('No batch history yet'), findsOneWidget);
    expect(find.text('Every generated batch is kept here.'), findsOneWidget);
  });

  testWidgets('批次卡片：时间 / 首数 / 未解析 / 来源 / 当前徽标 / 偏好摘要', (tester) async {
    await pumpWithBatches(tester);

    expect(find.byKey(Key('aiDjHistoryEntry_${provider.historyEntries[0].id}')),
        findsOneWidget);
    expect(find.byKey(Key('aiDjHistoryEntry_${provider.historyEntries[1].id}')),
        findsOneWidget);
    expect(find.text('Current'), findsOneWidget);
    expect(find.textContaining('3 tracks'), findsNWidgets(2));
    expect(find.textContaining('1 not found'), findsNWidgets(2));
    expect(find.textContaining('From a refresh'), findsNWidgets(2));
    expect(find.textContaining('Balanced'), findsNWidgets(2));
  });

  testWidgets('动作组：active 2 个平级动作，非 active 3 个 + 行尾删除图标', (tester) async {
    await pumpWithBatches(tester);
    final activeId = provider.activeBatchId!;
    final oldId = provider.historyEntries.last.id;
    final activeGroup = tester.widget<M3EButtonGroup>(
      find.byKey(Key('aiDjHistoryActions_$activeId')),
    );
    final oldGroup = tester.widget<M3EButtonGroup>(
      find.byKey(Key('aiDjHistoryActions_$oldId')),
    );

    expect(activeGroup.actions, hasLength(2));
    expect(oldGroup.actions, hasLength(3));
    expect(action(activeId, 'Play this batch'), findsOneWidget);
    expect(action(activeId, 'Add to queue'), findsOneWidget);
    expect(action(activeId, 'Set as current'), findsNothing);
    expect(
      find.descendant(
        of: card(activeId),
        matching: find.byIcon(Icons.delete_rounded),
      ),
      findsOneWidget,
    );
  });

  testWidgets('删除图标带「删除这批推荐」语义标签', (tester) async {
    await pumpWithBatches(tester);
    final activeId = provider.activeBatchId!;
    final oldId = provider.historyEntries.last.id;

    for (final id in [activeId, oldId]) {
      final button = tester.widget<M3EIconButton>(
        find.byKey(Key('aiDjHistoryDelete_$id')),
      );
      expect(button.semanticLabel, 'Delete this batch');
    }
  });

  testWidgets('展开：按需加载曲目（歌名 / 歌手 / 来源 / 理由）', (tester) async {
    await pumpHistory(tester);
    await tester.runAsync(createTwoBatches);
    await tester.pumpAndSettle();
    final oldId = provider.historyEntries.last.id;

    expect(find.text('Song 0'), findsNothing);

    await tester.tap(find.byKey(Key('aiDjHistoryExpand_$oldId')));
    await tester.pumpAndSettle();

    expect(find.text('Song 0'), findsOneWidget);
    expect(find.text('Artist · 网易云音乐'), findsNWidgets(3));
    expect(find.text('reason 0'), findsOneWidget);
    expect(find.text('Hide tracks'), findsOneWidget);
  });

  testWidgets('播放这批：切换 active 并强制替换队列', (tester) async {
    await pumpHistory(tester);
    await tester.runAsync(createTwoBatches);
    await tester.pumpAndSettle();
    final oldId = provider.historyEntries.last.id;

    await tapAction(tester, oldId, 'Play this batch');
    await settleAction(tester);

    expect(provider.activeBatchId, oldId);
    expect(backend.lastRequest?.tracks.map((track) => track.id.id).toList(),
        ['0', '1', '2']);
    expect(backend.lastRequest?.context?.name, kAiDjContextName);
  });

  testWidgets('加入队列：只追加未入队曲目，不切换 active', (tester) async {
    await pumpHistory(tester);
    await tester.runAsync(createTwoBatches);
    await tester.pumpAndSettle();
    final oldId = provider.historyEntries.last.id;
    final activeId = provider.activeBatchId;

    await tapAction(tester, oldId, 'Add to queue');
    await settleAction(tester);

    expect(backend.lastEnqueued?.map((track) => track.id.id).toList(),
        ['0', '1', '2']);
    expect(provider.activeBatchId, activeId);
  });

  testWidgets('设为当前：只切换浏览列表，不动队列', (tester) async {
    await pumpHistory(tester);
    await tester.runAsync(createTwoBatches);
    await tester.pumpAndSettle();
    final oldId = provider.historyEntries.last.id;
    final activeId = provider.activeBatchId;
    backend.calls.clear();

    await tapAction(tester, oldId, 'Set as current');
    await settleAction(tester);

    expect(provider.activeBatchId, oldId);
    expect(backend.calls, isEmpty);
    expect(activeId, isNot(oldId));
  });

  testWidgets('删除历史：只删记录，不动队列', (tester) async {
    await pumpHistory(tester);
    await tester.runAsync(createTwoBatches);
    await tester.pumpAndSettle();
    final oldId = provider.historyEntries.last.id;
    final activeId = provider.activeBatchId;
    backend.calls.clear();

    await tester.tap(find.byKey(Key('aiDjHistoryDelete_$oldId')));
    await settleAction(tester);

    expect(provider.historyEntries.map((entry) => entry.id), [activeId]);
    expect(find.byKey(Key('aiDjHistoryEntry_$oldId')), findsNothing);
    expect(backend.calls, isEmpty);
  });

  testWidgets('窄屏：溢出菜单可触达被隐藏动作', (tester) async {
    await pumpHistory(tester);
    tester.view.physicalSize = const Size(320, 1600);
    await tester.runAsync(createTwoBatches);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final oldId = provider.historyEntries.last.id;
    final activeId = provider.activeBatchId;
    expect(find.byKey(Key('aiDjHistoryActions_$oldId')), findsOneWidget);
    expect(find.byKey(Key('aiDjHistoryDelete_$oldId')), findsOneWidget);

    final overflow = find.descendant(
      of: card(oldId),
      matching: find.byIcon(Icons.more_horiz_rounded),
    );
    expect(overflow, findsOneWidget);
    await tester.tap(overflow);
    await tester.pumpAndSettle();

    final hidden = find.text('Set as current').hitTestable();
    expect(hidden, findsOneWidget);
    await tester.tap(hidden);
    await settleAction(tester);

    expect(provider.activeBatchId, oldId);
    expect(activeId, isNot(oldId));
  });

  testWidgets('清空历史：确认后保留 active', (tester) async {
    await pumpHistory(tester);
    await tester.runAsync(createTwoBatches);
    await tester.pumpAndSettle();
    final activeId = provider.activeBatchId;

    await tester.tap(find.byKey(const Key('aiDjHistoryClearButton')));
    await tester.pumpAndSettle();
    expect(find.text('Clear recommendation history?'), findsOneWidget);
    expect(
      find.textContaining('Only history records are removed'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('aiDjHistoryClearConfirm')));
    await settleAction(tester);

    expect(provider.historyEntries, hasLength(1));
    expect(provider.activeBatchId, activeId);
    expect(find.text('Recommendation history cleared'), findsOneWidget);
  });
}
