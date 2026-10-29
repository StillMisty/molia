import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/ai_dj_history_page.dart';
import 'package:molia/pages/ai_dj_page.dart';
import 'package:molia/pages/ai_dj_preferences_page.dart';
import 'package:molia/providers/ai_dj_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/ai/ai_settings_store.dart';
import 'package:molia/widgets/ai_dj_track_tile.dart';
import 'package:molia/widgets/playing_indicator.dart';

import 'support/fake_ai_generator.dart';
import 'support/fake_library_repository.dart';
import 'support/fakes.dart';
import 'support/settings_test_support.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playbackProvider;
  late LibraryProvider libraryProvider;
  late FakeAiDjGenerator generator;
  late MemorySettingsSecretStore secrets;
  late AiDjProvider provider;

  Future<void> pumpProvider({bool withConfig = true}) async {
    final prefs = await SharedPreferences.getInstance();
    if (withConfig) {
      await AiSettingsStore(
              settings:
                  testSettingsRegistry(preferences: prefs, secrets: secrets))
          .saveConfig(
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
      settingsStore: AiSettingsStore(
          settings: testSettingsRegistry(preferences: prefs, secrets: secrets)),
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
    secrets = MemorySettingsSecretStore();
    backend = FakePlaybackBackend();
    playbackProvider = buildTestPlaybackProvider(backend: backend);
    await playbackProvider.preferencesReady;
    libraryProvider = LibraryProvider(
      repository: FakeLibraryRepository(),
      playbackProvider: playbackProvider,
    );
    generator = FakeAiDjGenerator(batchFactory: () => _batch(0, 3));
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

  testWidgets('首次开启：隐私确认 → 生成当前推荐（带理由 + 上次更新）', (tester) async {
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
    // 行尾只显示歌手，不再暴露命中渠道。
    expect(find.text('Artist'), findsWidgets);
    expect(find.text('Artist · wy'), findsNothing);
  });

  testWidgets('当前曲目：推荐卡封面角标跟随播放 / 暂停', (tester) async {
    await pumpProvider();
    await pumpPage(tester);
    await provider.grantConsent();
    await provider.setEnabled(true);
    await tester.pumpAndSettle();

    final track = _batch(0, 3).items.first.track;
    backend.emit(BackendSnapshot(
      current: track,
      queue: [track],
      currentIndex: 0,
      isPlaying: true,
    ));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PlayingIndicator), findsOneWidget);

    backend.emit(BackendSnapshot(
      current: track,
      queue: [track],
      currentIndex: 0,
    ));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byIcon(Icons.pause_rounded), findsNothing);
    expect(find.byType(PlayingIndicator), findsOneWidget);
  });

  testWidgets('播放全部 / 加入队列 / 换一批 / 历史入口', (tester) async {
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

    // 每批数量只在推荐偏好页，主页面不再有下拉。
    expect(find.byKey(const Key('aiDjBatchSizeDropdown')), findsNothing);

    generator.batchFactory = () => _batch(9, 3);
    await tester.tap(find.byKey(const Key('aiDjRefreshBatchButton')));
    await tester.pumpAndSettle();
    expect(generator.calls, greaterThanOrEqualTo(2));
    expect(generator.lastCount, 10);
    expect(find.text('Song 9'), findsOneWidget);

    await tester.tap(find.byKey(const Key('aiDjHistoryButton')));
    await tester.pumpAndSettle();
    expect(find.byType(AiDjHistoryPage), findsOneWidget);
  });

  testWidgets('推荐偏好行：摘要 + 进入偏好页', (tester) async {
    await pumpProvider();
    await pumpPage(tester);
    await provider.grantConsent();
    await provider.setEnabled(true);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('aiDjPreferencesRow')), findsOneWidget);
    expect(find.text('Recommendation preferences'), findsOneWidget);

    await provider.savePreferences(
      provider.preferences.copyWith(styles: ['pop'], autoFeed: false),
    );
    await tester.pumpAndSettle();
    // 偏好即时保存，不再提示“换一批生效”。
    expect(find.textContaining('Preferences updated'), findsNothing);
    expect(find.textContaining('Pop'), findsOneWidget);

    await tester.tap(find.byKey(const Key('aiDjPreferencesRow')));
    await tester.pumpAndSettle();
    expect(find.byType(AiDjPreferencesPage), findsOneWidget);
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

  testWidgets('单曲操作：换一首 / 多来点这种 / 不感兴趣 + 撤销', (tester) async {
    await pumpProvider();
    await pumpPage(tester);
    await provider.grantConsent();
    await provider.setEnabled(true);
    await tester.pumpAndSettle();

    generator.batchFactory = () => _batch(7, 1);
    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Swap this one'));
    await tester.pumpAndSettle();
    expect(provider.recommendations?.items.first.track.id.id, '7');
    expect(generator.lastCount, 1);

    // 多来点这种：写入种子。
    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('More like this'));
    await tester.pumpAndSettle();
    expect(provider.seeds, ['Song 7 - Artist']);

    // 不感兴趣 → 列表移除 + 本轮反馈出现。
    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not interested'));
    await tester.pumpAndSettle();
    expect(provider.notInterestedItems, hasLength(1));
    expect(find.textContaining('Not interested ·'), findsOneWidget);

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

  testWidgets('发送透明化：页面只留入口，内容在弹窗里切换', (tester) async {
    generator.preview = const AiPrompt(
      systemPrompt: 'SYSTEM PROMPT',
      userPrompt: 'USER PROMPT',
    );
    generator.batchFactory = () => _batch(0, 3).copyWith(
          prompt: const AiPrompt(
            systemPrompt: 'LAST SYSTEM',
            userPrompt: 'LAST USER',
          ),
          rawResponse: 'RAW RESPONSE',
        );
    await pumpProvider();
    await pumpPage(tester);
    await provider.grantConsent();
    await provider.setEnabled(true);
    await tester.pumpAndSettle();

    expect(find.text('What gets sent to AI'), findsOneWidget);
    expect(find.byKey(const Key('aiDjPromptRow')), findsOneWidget);
    expect(
      find.textContaining('No play links, device information or API key.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('aiDjPromptRow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('aiDjPromptDialog')), findsOneWidget);
    expect(find.text('SYSTEM PROMPT'), findsOneWidget);
    expect(find.text('USER PROMPT'), findsOneWidget);

    await tester.tap(find.text('Last sent'));
    await tester.pumpAndSettle();
    expect(find.textContaining('LAST USER'), findsOneWidget);

    await tester.tap(find.text('Last reply'));
    await tester.pumpAndSettle();
    expect(find.text('RAW RESPONSE'), findsOneWidget);
  });

  testWidgets('显式生成：状态卡（阶段 / 等待 / 停止）', (tester) async {
    generator.emitProgress = true;
    await pumpProvider();
    await pumpPage(tester);
    await provider.grantConsent();
    final gate = Completer<void>();
    generator.gate = gate;

    unawaited(provider.setEnabled(true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('aiDjGenerationCard')), findsOneWidget);
    expect(find.text('Generating recommendations'), findsOneWidget);
    expect(find.textContaining('Finding songs'), findsOneWidget);
    expect(find.textContaining('Waiting'), findsOneWidget);

    await tester.tap(find.byKey(const Key('aiDjCancelGenerationButton')));
    await tester.pump();
    expect(provider.isBusy, isFalse);
    expect(provider.progress, isNull);
    expect(provider.recommendations, isNull);
    expect(provider.lastError, isNull);

    gate.complete();
    await tester.pumpAndSettle();
    expect(provider.recommendations, isNull, reason: '取消后晚到结果丢弃');
  });

  testWidgets('首次生成骨架：空列表时显示脉冲骨架', (tester) async {
    await pumpProvider();
    await pumpPage(tester);
    await provider.grantConsent();
    final gate = Completer<void>();
    generator.gate = gate;

    unawaited(provider.setEnabled(true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('aiDjPulsingSkeleton')), findsOneWidget);
    expect(find.text('No recommendations yet'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(provider.recommendations, isNotNull);
  });

  testWidgets('收藏收进行尾菜单：行内无独立收藏按钮，菜单可切换', (tester) async {
    await pumpProvider();
    await pumpPage(tester);
    await provider.grantConsent();
    await provider.setEnabled(true);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.favorite_border_rounded), findsNothing);

    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to favorites'));
    await tester.pumpAndSettle();
    expect(libraryProvider.isFavorite('wy', '0'), isTrue);

    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from favorites'));
    await tester.pumpAndSettle();
    expect(libraryProvider.isFavorite('wy', '0'), isFalse);
  });

  testWidgets(
    '桌面：推荐行无 ⋮，右键在落点弹出同一份菜单',
    (tester) async {
      await pumpProvider();
      await pumpPage(tester);
      await provider.grantConsent();
      await provider.setEnabled(true);
      await tester.pumpAndSettle();

      expect(
        find.byIcon(Icons.more_vert_rounded),
        findsNothing,
        reason: '桌面入口是行表面右键，不再有行尾 ⋮',
      );

      await tester.tap(
        find.byType(AiDjTrackTile).first,
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('Add to favorites'), findsOneWidget);
      expect(find.text('Swap this one'), findsOneWidget);
      expect(find.text('More like this'), findsOneWidget);
      expect(find.text('Not interested'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('配置表单：自定义地址时「自定义」筛选芯片可用且选中', (tester) async {
    await pumpProvider();
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('aiDjManageConfigButton')));
    await tester.pumpAndSettle();

    final chipFinder = find.byKey(const Key('aiDjCustomPresetChip'));
    expect(chipFinder, findsOneWidget);
    expect(tester.widget<M3EChip>(chipFinder).selected, isTrue,
        reason: '测试配置本身就是自定义地址');
    expect(tester.widget<M3EChip>(chipFinder).onPressed, isNotNull);

    await tester.tap(find.text('DeepSeek'));
    await tester.pumpAndSettle();
    expect(tester.widget<M3EChip>(chipFinder).selected, isFalse);

    await tester.enterText(
      find.byKey(const Key('aiDjBaseUrlField')),
      'https://custom.example/v1',
    );
    await tester.pump();

    final chip = tester.widget<M3EChip>(chipFinder);
    expect(chip.selected, isTrue);
    expect(chip.onPressed, isNotNull, reason: '芯片必须可点击');
  });

  testWidgets('测试连接成功：自动保存表单里的新配置并收起表单', (tester) async {
    await pumpProvider();
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('aiDjManageConfigButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('aiDjBaseUrlField')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('aiDjApiKeyField')), 'sk-new');
    await tester.tap(find.text('Test connection').hitTestable());
    await tester.pumpAndSettle();

    expect(provider.config?.apiKey, 'sk-new');
    expect(find.byKey(const Key('aiDjBaseUrlField')), findsNothing);
    expect(find.text('Connected — config saved'), findsOneWidget);
  });
}
