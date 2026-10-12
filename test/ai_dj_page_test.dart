import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/ai_dj_page.dart';
import 'package:molia/providers/ai_dj_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/ai/ai_recommendation_service.dart';
import 'package:molia/services/ai/ai_settings_store.dart';

import 'support/fake_library_repository.dart';
import 'support/fakes.dart';

/// 假生成器：脚本化推荐列表（不触碰 LLM/网络）。
class _FakeGenerator implements AiRecommendationGenerator {
  int calls = 0;
  int? lastCount;
  List<String> lastExcluded = const [];
  AiUpstreamSummary summary = const AiUpstreamSummary(
    recentEvents: 12,
    topArtists: 3,
    topTracks: 5,
    exclusions: 7,
  );

  AiDjBatch Function() batchFactory = () => _batch(0, 3);

  @override
  Future<AiDjBatch> generate({
    required LlmConfig config,
    required int count,
    List<String> skippedLabels = const [],
    List<String> likedLabels = const [],
    List<String> excludeLabels = const [],
  }) async {
    calls++;
    lastCount = count;
    lastExcluded = excludeLabels;
    return batchFactory();
  }

  @override
  Future<void> testConnection(LlmConfig config) async {}

  @override
  Future<AiUpstreamSummary> summarizeUpstream() async => summary;
}

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
          ),
      ],
      unresolved: const [AiRecommendation(title: 'Ghost Song', artist: 'X')],
      generatedAt: DateTime.now(),
    );

class _MemorySecrets implements AiSecretStorage {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playbackProvider;
  late LibraryProvider libraryProvider;
  late _FakeGenerator generator;
  late _MemorySecrets secrets;
  late AiDjProvider provider;

  Future<void> pumpProvider({bool withConfig = true}) async {
    final prefs = await SharedPreferences.getInstance();
    if (withConfig) {
      await AiSettingsStore(secrets: secrets, preferences: prefs).saveConfig(
        const LlmConfig(
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'sk-test',
          model: 'm',
        ),
      );
    } else {
      secrets.data.clear();
    }
    provider = AiDjProvider(
      playbackProvider: playbackProvider,
      libraryProvider: libraryProvider,
      recommendationService: generator,
      settingsStore: AiSettingsStore(secrets: secrets, preferences: prefs),
    );
    await provider.init();
  }

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
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
          home: const AiDjPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secrets = _MemorySecrets();
    backend = FakePlaybackBackend();
    playbackProvider = buildTestPlaybackProvider(backend: backend);
    await playbackProvider.preferencesReady;
    libraryProvider = LibraryProvider(
      repository: FakeLibraryRepository(),
      playbackProvider: playbackProvider,
    );
    generator = _FakeGenerator();
  });

  tearDown(() {
    provider.dispose();
    libraryProvider.dispose();
    playbackProvider.dispose();
  });

  testWidgets('未配置：展示配置表单，开启被拦截并提示', (tester) async {
    await pumpProvider(withConfig: false);
    await pumpPage(tester);

    expect(find.byKey(const Key('aiDjBaseUrlField')), findsOneWidget);
    expect(find.byKey(const Key('aiDjSaveConfigButton')), findsOneWidget);

    await tester.tap(find.byKey(const Key('aiDjModeSwitch')));
    await tester.pumpAndSettle();

    expect(provider.enabled, isFalse);
    expect(provider.status, AiDjStatus.off);
    expect(find.text('AI service is not configured yet'), findsOneWidget);
  });

  testWidgets('首次开启：隐私确认 → 生成今日推荐（带理由 + 上次更新）', (tester) async {
    await pumpProvider();
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('aiDjModeSwitch')));
    await tester.pumpAndSettle();

    expect(find.text('Before you start'), findsOneWidget);

    await tester.tap(find.byKey(const Key('aiDjConsentAgreeButton')));
    await tester.pumpAndSettle();

    expect(provider.enabled, isTrue);
    expect(provider.status, AiDjStatus.off, reason: '启用不接管播放');
    expect(generator.calls, 1);
    expect(find.text("Today's picks"), findsOneWidget);
    expect(find.textContaining('Updated'), findsOneWidget);
    expect(find.text('Song 0'), findsOneWidget);
    expect(find.text('reason 0'), findsOneWidget);
    expect(find.textContaining('1 not found'), findsOneWidget);
  });

  testWidgets('播放全部 / 加入队列 / 换一批', (tester) async {
    await pumpProvider();
    await pumpPage(tester);
    await provider.grantConsent();
    await provider.setEnabled(true);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('aiDjPlayAllButton')));
    await tester.pumpAndSettle();
    expect(provider.status, AiDjStatus.playing);
    expect(backend.lastRequest?.context?.name, kAiDjContextName);
    expect(backend.lastRequest?.startIndex, 0);

    await tester.tap(find.byKey(const Key('aiDjEnqueueAllButton')));
    await tester.pumpAndSettle();
    expect(backend.lastEnqueued, hasLength(3));

    generator.batchFactory = () => _batch(9, 3);
    await tester.tap(find.byKey(const Key('aiDjRefreshBatchButton')));
    await tester.pumpAndSettle();
    expect(generator.calls, greaterThanOrEqualTo(2));
    expect(find.text('Song 9'), findsOneWidget);
  });

  testWidgets('空列表：显式「生成推荐」', (tester) async {
    await pumpProvider();
    await pumpPage(tester);
    // 未确认隐私 → 启用不自动生成。
    await provider.setEnabled(true);
    await tester.pumpAndSettle();

    expect(find.text('No recommendations yet'), findsOneWidget);
    await tester.tap(find.byKey(const Key('aiDjGenerateButton')));
    await tester.pumpAndSettle();

    expect(provider.hasRecommendations, isTrue);
    expect(find.text('Song 0'), findsOneWidget);
  });

  testWidgets('单曲操作：换一首 / 不感兴趣 + 撤销', (tester) async {
    await pumpProvider();
    await pumpPage(tester);
    await provider.grantConsent();
    await provider.setEnabled(true);
    await tester.pumpAndSettle();

    // 换一首（行内菜单第一条）。
    generator.batchFactory = () => _batch(7, 1);
    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Swap this one'));
    await tester.pumpAndSettle();
    expect(provider.recommendations?.items.first.track.id.id, '7');
    expect(generator.lastCount, 1);

    // 不感兴趣（同一菜单第二条）→ 列表移除 + 反馈面板出现。
    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not interested'));
    await tester.pumpAndSettle();
    expect(provider.notInterestedItems, hasLength(1));
    expect(find.textContaining('Not interested ·'), findsOneWidget);

    // 撤销：点反馈 chip 原位插回。
    await tester.tap(find.textContaining('Not interested ·'));
    await tester.pumpAndSettle();
    expect(provider.notInterestedItems, isEmpty);
  });

  testWidgets('保存配置：预设填充 + 保存后收起表单', (tester) async {
    await pumpProvider(withConfig: false);
    await pumpPage(tester);

    await tester.tap(find.text('DeepSeek'));
    await tester.pumpAndSettle();
    expect(
      (tester
          .widget<M3ETextField>(find.byKey(const Key('aiDjBaseUrlField')))
          .controller
          ?.text),
      'https://api.deepseek.com',
    );

    await tester.enterText(find.byKey(const Key('aiDjApiKeyField')), 'sk-x');
    await tester.enterText(
        find.byKey(const Key('aiDjModelField')), 'deepseek-chat');
    await tester.tap(find.byKey(const Key('aiDjSaveConfigButton')));
    await tester.pumpAndSettle();

    expect(provider.hasConfig, isTrue);
    expect(provider.config?.apiKey, 'sk-x');
    expect(find.byKey(const Key('aiDjBaseUrlField')), findsNothing);
  });

  testWidgets('本次发送的数据：展开显示条数摘要', (tester) async {
    await pumpProvider();
    await pumpPage(tester);
    await provider.grantConsent();
    await provider.setEnabled(true);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.expand_more_rounded));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Latest 12 play events'),
      findsOneWidget,
    );
    expect(find.textContaining('top 3 artists'), findsOneWidget);
  });
}
