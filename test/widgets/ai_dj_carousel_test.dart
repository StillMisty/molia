import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/ai_dj_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/ai/ai_recommendation_service.dart';
import 'package:molia/services/ai/ai_settings_store.dart';
import 'package:molia/widgets/ai_dj_carousel.dart';

import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

/// 假生成器：脚本化批次（不触碰 LLM/网络）。
class _FakeGenerator implements AiRecommendationGenerator {
  _FakeGenerator(this.batchFactory);

  AiDjBatch Function() batchFactory;
  int calls = 0;

  @override
  Future<AiDjBatch> generate({
    required LlmConfig config,
    required int count,
    List<String> skippedLabels = const [],
    List<String> likedLabels = const [],
  }) async {
    calls++;
    return batchFactory();
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

AiDjBatch _batch(int from, int count) => AiDjBatch(
      items: [
        for (var i = 0; i < count; i++)
          ResolvedRecommendation(
            source: AiRecommendation(
              title: 'Song ${from + i}',
              artist: 'Artist',
              reason: 'Reason ${from + i}',
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
      generatedAt: DateTime.now(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playbackProvider;
  late LibraryProvider libraryProvider;
  late _FakeGenerator generator;
  late _MemorySecrets secrets;
  late AiDjProvider provider;
  var providerCreated = false;

  Future<void> pumpProvider({bool withConfig = true}) async {
    providerCreated = true;
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

  Future<void> pumpCarousel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1000);
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
          home: const Scaffold(
            body: SingleChildScrollView(child: AiDjCarousel()),
          ),
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
    generator = _FakeGenerator(() => _batch(0, 3));
  });

  tearDown(() {
    if (providerCreated) provider.dispose();
    providerCreated = false;
    libraryProvider.dispose();
    playbackProvider.dispose();
  });

  testWidgets('模式生效：渲染推荐 carousel，点卡即从该首起播', (tester) async {
    await pumpProvider();
    await provider.grantConsent();
    generator.batchFactory = () => _batch(0, 3);
    await provider.ensurePendingBatch();
    await provider.playFromPending(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    await pumpCarousel(tester);

    expect(find.byKey(const Key('aiDjCarousel')), findsOneWidget);
    expect(find.text('Song 0'), findsOneWidget);
    expect(find.text('Reason 0'), findsOneWidget);

    await tester.tap(find.text('Song 1'));
    await tester.pumpAndSettle();

    expect(provider.status, AiDjStatus.playing);
    expect(backend.lastRequest?.tracks.first.title, 'Song 0');
    expect(backend.lastRequest?.startIndex, 1);
  });

  testWidgets('模式生效：滑到末尾显示「换一批」卡，点击触发重新生成', (tester) async {
    await pumpProvider();
    await provider.grantConsent();
    generator.batchFactory = () => _batch(0, 3);
    await provider.ensurePendingBatch();
    await provider.playFromPending(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    await pumpCarousel(tester);
    final callsBefore = generator.calls;

    // 每次甩动推进一张卡（carousel 默认单步吸附，需要速度判定）。
    for (var i = 0; i < 5 && find.text('New batch').evaluate().isEmpty; i++) {
      await tester.fling(
        find.byKey(const Key('aiDjCarousel')),
        const Offset(-400, 0),
        1200,
      );
      await tester.pumpAndSettle();
    }
    expect(find.text('New batch'), findsOneWidget);

    await tester.tap(find.text('New batch'));
    await tester.pumpAndSettle();

    expect(generator.calls, greaterThan(callsBefore));
  });

  testWidgets('模式生效但生成失败：展示重试卡，点击触发重新生成', (tester) async {
    await pumpProvider();
    await provider.grantConsent();
    generator.batchFactory = () => _batch(0, 3);
    await provider.ensurePendingBatch();
    // 起播后生成开始失败：预取失败 → 无待播批次，模式仍在生效。
    generator.batchFactory = () => AiDjBatch(
          items: const [],
          generatedAt: DateTime.now(),
        );
    await provider.playFromPending(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(provider.status, AiDjStatus.playing);
    expect(provider.hasPendingBatch, isFalse);

    await pumpCarousel(tester);

    expect(find.byKey(const Key('aiDjBatchErrorCard')), findsOneWidget);
    final callsBefore = generator.calls;

    await tester.tap(find.byKey(const Key('aiDjBatchErrorCard')));
    await tester.pumpAndSettle();

    expect(generator.calls, greaterThan(callsBefore));
  });

  testWidgets('模式关闭：即使已配置且有待播批次也整条隐藏', (tester) async {
    await pumpProvider();
    await provider.grantConsent();
    generator.batchFactory = () => _batch(0, 3);
    await provider.ensurePendingBatch();
    expect(provider.hasPendingBatch, isTrue);

    await pumpCarousel(tester);

    expect(find.byKey(const Key('aiDjCarousel')), findsNothing);
    expect(find.text('Song 0'), findsNothing);
  });

  testWidgets('未注册 AI provider 的上下文：整条隐藏', (tester) async {
    providerCreated = false;
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      M3EMaterialApp(
        data: M3EThemeData.fromMaterial(ThemeData()),
        theme: ThemeData(),
        home: const Scaffold(body: AiDjCarousel()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('aiDjCarousel')), findsNothing);
  });
}
