import 'dart:async';

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
import 'package:molia/widgets/ai_dj_track_tile.dart';
import 'package:molia/widgets/ai_dj_waiting.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/ai_dj_test_support.dart';
import '../support/cover_test_support.dart';
import '../support/provider_test_scope.dart';
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
        sourceName: '网易音乐',
      ),
  ],
  generatedAt: DateTime.now(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('配置没有保存按钮，输入停顿后写回 provider', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final registry = testSettingsRegistry();
    await AiSettingsStore(settings: registry).saveConfig(
      const LlmConfig(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-test',
        model: 'model-a',
      ),
    );
    final playback = buildTestPlaybackProvider(
      settings: registry,
      facade: FakePlaybackFacade(),
    );
    await playback.preferencesReady;
    final library = LibraryProvider(
      repository: FakeLibraryRepository(),
      playbackProvider: playback,
    );
    final provider = AiDjProvider(
      playbackProvider: playback,
      libraryProvider: library,
      recommendationService: FakeAiDjGenerator(),
      settingsStore: AiSettingsStore(settings: registry),
      recommendationStore: testAiRecommendationStore(),
    );
    await provider.init();
    addTearDown(() {
      provider.dispose();
      library.dispose();
      playback.dispose();
    });

    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scope = ProviderTestScope();
    scope.put<AiDjProvider>(provider);
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
          home: const AiDjPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('aiDjSaveConfigButton')), findsNothing);

    await tester.tap(find.byKey(const Key('aiDjManageConfigButton')));
    await tester.pumpAndSettle();

    expect(find.text('改动即时生效'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('aiDjModelField')), 'model-b');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(provider.state.config?.model, 'model-b');
  });

  testWidgets('配置表单有显式完成按钮，收起前补存未落盘的输入', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final registry = testSettingsRegistry();
    await AiSettingsStore(settings: registry).saveConfig(
      const LlmConfig(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-test',
        model: 'model-a',
      ),
    );
    final playback = buildTestPlaybackProvider(
      settings: registry,
      facade: FakePlaybackFacade(),
    );
    await playback.preferencesReady;
    final library = LibraryProvider(
      repository: FakeLibraryRepository(),
      playbackProvider: playback,
    );
    final provider = AiDjProvider(
      playbackProvider: playback,
      libraryProvider: library,
      recommendationService: FakeAiDjGenerator(),
      settingsStore: AiSettingsStore(settings: registry),
      recommendationStore: testAiRecommendationStore(),
    );
    await provider.init();
    addTearDown(() {
      provider.dispose();
      library.dispose();
      playback.dispose();
    });

    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scope = ProviderTestScope();
    scope.put<AiDjProvider>(provider);
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
          home: const AiDjPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('aiDjManageConfigButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('aiDjConfigDoneButton')), findsOneWidget);
    expect(find.widgetWithText(M3EButton, '完成'), findsOneWidget);

    // 不等 400ms 防抖：完成按钮本身就是「保存并收起」。
    await tester.enterText(find.byKey(const Key('aiDjModelField')), 'model-b');
    await tester.tap(find.byKey(const Key('aiDjConfigDoneButton')));
    await tester.pumpAndSettle();

    expect(provider.state.config?.model, 'model-b');
    expect(find.byKey(const Key('aiDjConfigDoneButton')), findsNothing);
    expect(find.text('https://api.example.com/v1'), findsOneWidget);
  });

  testWidgets('播放全部 / 换一批收成分裂按钮，历史固定在顶栏', (tester) async {
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

    // 手机窄宽：两颗分裂按钮允许换行，但按钮排本身不能溢出。
    tester.view.physicalSize = const Size(360, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final scope = ProviderTestScope();
    scope.put<AiDjProvider>(ai);
    scope.put<PlaybackProvider>(playback);
    scope.put<LibraryProvider>(library);
    putCoverStore(scope);
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
          home: const AiDjPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 主操作收进分裂按钮：播放全部 filled、换一批 tonal。
    expect(
      tester
          .widget<M3ESplitButton<Object?>>(
            find.byKey(const Key('aiDjPlayAllSplitButton')),
          )
          .style,
      M3EButtonStyle.filled,
    );
    expect(
      tester
          .widget<M3ESplitButton<Object?>>(
            find.byKey(const Key('aiDjRefreshSplitButton')),
          )
          .style,
      M3EButtonStyle.tonal,
    );
    // 旧的独立按钮与顶栏「更多」溢出菜单都已移除。
    expect(find.byKey(const Key('aiDjPlayAllButton')), findsNothing);
    expect(find.byKey(const Key('aiDjEnqueueAllButton')), findsNothing);
    expect(find.byKey(const Key('aiDjMoreButton')), findsNothing);

    // 历史改成顶栏固定图标入口，不再藏在菜单里。
    expect(find.byKey(const Key('aiDjHistoryButton')), findsOneWidget);

    Future<void> openTrailingMenu(Key key) async {
      final arrow = find.descendant(
        of: find.byKey(key),
        matching: find.byIcon(M3EIcons.keyboard_arrow_down),
      );
      expect(arrow, findsOneWidget);
      await tester.tap(arrow);
      await tester.pumpAndSettle();
    }

    // 播放全部 ▾ 加入队列。
    await openTrailingMenu(const Key('aiDjPlayAllSplitButton'));
    expect(find.text(l10n.aiDjEnqueueAll), findsOneWidget);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    // 换一批 ▾ 补一批到队尾；历史不在菜单里。
    await openTrailingMenu(const Key('aiDjRefreshSplitButton'));
    expect(find.text(l10n.aiDjFeedBatch), findsOneWidget);
    expect(find.text(l10n.aiDjHistoryTitle), findsNothing);
  });

  testWidgets('生成中旧列表仍可点播，且只留一条进度带', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final backend = FakePlaybackFacade();
    final playback = buildTestPlaybackProvider(facade: backend);
    await playback.preferencesReady;
    final library = LibraryProvider(
      repository: FakeLibraryRepository(),
      playbackProvider: playback,
    );
    final prefs = await SharedPreferences.getInstance();
    final settings = testSettingsRegistry(
      preferences: prefs,
      secrets: MemorySettingsSecretStore(),
    );
    await AiSettingsStore(settings: settings).saveConfig(
      const LlmConfig(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-test',
        model: 'm',
      ),
    );
    final generator = FakeAiDjGenerator(batchFactory: _batch);
    final ai = AiDjProvider(
      playbackProvider: playback,
      libraryProvider: library,
      recommendationService: generator,
      settingsStore: AiSettingsStore(settings: settings),
      recommendationStore: AiRecommendationStore(
        preferences: prefs,
        directoryProvider: () async => null,
      ),
    );
    await ai.init();
    await ai.grantConsent();
    await ai.setEnabled(true);
    expect(ai.state.recommendations?.items, hasLength(3));
    addTearDown(() {
      ai.dispose();
      library.dispose();
      playback.dispose();
    });

    // 第二批挂起：页面停在「生成中 + 旧列表还在」。
    final gate = Completer<void>();
    generator
      ..gate = gate
      ..emitProgress = true;
    final generating = ai.refreshRecommendations();

    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scope = ProviderTestScope();
    scope.put<AiDjProvider>(ai);
    scope.put<PlaybackProvider>(playback);
    scope.put<LibraryProvider>(library);
    putCoverStore(scope);
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
          home: const AiDjPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 进度只留一条：没有骨架行、等待秒数或阶段步进。
    expect(find.byType(AiDjThinProgress), findsOneWidget);
    expect(find.byKey(const Key('aiDjPulsingSkeleton')), findsNothing);
    expect(find.textContaining('已等待'), findsNothing);
    expect(find.textContaining('正在找歌'), findsOneWidget);

    final tiles = tester.widgetList<AiDjTrackTile>(find.byType(AiDjTrackTile));
    expect(tiles, hasLength(3));
    for (final tile in tiles) {
      expect(tile.busy, isFalse, reason: '生成不是队列操作，不应整行禁用');
      expect(tile.canReplace, isFalse, reason: '换一首与显式生成互斥');
    }

    // 生成中点击旧列表仍能起播。
    await tester.tap(find.text('Song 0'));
    await tester.pump();
    expect(ai.state.status, AiDjStatus.playing);
    expect(backend.lastRequest?.startIndex, 0);

    gate.complete();
    await generating;
    await tester.pump();
  });

  testWidgets('细进度条带无障碍语义', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      M3EMaterialApp(
        data: M3EThemeData.fromMaterial(ThemeData.light()),
        theme: ThemeData.light(),
        home: const Scaffold(
          body: AiDjThinProgress(
            value: 0.5,
            semanticLabel: '推荐生成进度',
            semanticValue: '8/24',
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final node = tester.getSemantics(find.byType(AiDjThinProgress));
    expect(node.label, '推荐生成进度');
    expect(node.value, '8/24');
    semantics.dispose();
  });
}
