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

/// 假生成器：脚本化批次（不触碰 LLM/网络）。
class _FakeGenerator implements AiRecommendationGenerator {
  int calls = 0;

  @override
  Future<AiDjBatch> generate({
    required LlmConfig config,
    required int count,
    List<String> skippedLabels = const [],
    List<String> likedLabels = const [],
  }) async {
    calls++;
    return AiDjBatch(
      items: [
        for (var i = 0; i < 3; i++)
          ResolvedRecommendation(
            source: AiRecommendation(
              title: 'Song $i',
              artist: 'Artist',
              reason: 'reason $i',
            ),
            track: Track(
              id: TrackId('wy', '$i'),
              title: 'Song $i',
              artists: const [Artist(name: 'Artist')],
              duration: const Duration(seconds: 100),
              origin: TrackOrigin.builtin,
            ),
          ),
      ],
      unresolved: const [AiRecommendation(title: 'Ghost Song', artist: 'X')],
      generatedAt: DateTime(2026, 1, 1),
    );
  }

  @override
  Future<void> testConnection(LlmConfig config) async {}
}

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
    tester.view.physicalSize = const Size(800, 1800);
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

    expect(provider.status, AiDjStatus.off);
    expect(find.text('AI service is not configured yet'), findsOneWidget);
  });

  testWidgets('首次开启：隐私确认 → 开始推歌 → 批次带理由展示', (tester) async {
    await pumpProvider();
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('aiDjModeSwitch')));
    await tester.pumpAndSettle();

    expect(find.text('Before you start'), findsOneWidget);

    await tester.tap(find.byKey(const Key('aiDjConsentAgreeButton')));
    await tester.pumpAndSettle();

    expect(provider.status, AiDjStatus.playing);
    expect(generator.calls, 1);
    expect(find.text('Song 0'), findsWidgets);
    expect(find.text('reason 0'), findsOneWidget);
    expect(find.textContaining('1 not found'), findsOneWidget);
  });

  testWidgets('再来一批触发续推；停止对话框默认保留队列', (tester) async {
    await pumpProvider();
    await provider.grantConsent();
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('aiDjModeSwitch')));
    await tester.pumpAndSettle();
    expect(provider.status, AiDjStatus.playing);

    await tester.tap(find.byKey(const Key('aiDjFeedMoreButton')));
    await tester.pumpAndSettle();
    expect(generator.calls, 2);

    await tester.tap(find.byKey(const Key('aiDjModeSwitch')));
    await tester.pumpAndSettle();
    expect(find.text('Exit AI DJ?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('aiDjStopKeepQueueButton')));
    await tester.pumpAndSettle();

    expect(provider.status, AiDjStatus.off);
    expect(backend.calls, isNot(contains('stop')));
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
}
