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
import 'package:molia/pages/ai_dj_page.dart';
import 'package:molia/providers/ai_dj_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:molia/services/ai/ai_settings_store.dart';
import 'package:molia/widgets/ai_dj_carousel.dart';
import 'package:molia/widgets/ai_dj_waiting.dart';
import 'package:molia/widgets/library_search_tab.dart';

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
  late FakeAiDjGenerator generator;
  late MemorySettingsSecretStore secrets;
  late AiDjProvider provider;
  var providerCreated = false;

  Future<void> pumpProvider({bool withConfig = true}) async {
    providerCreated = true;
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
    if (providerCreated) provider.dispose();
    providerCreated = false;
    libraryProvider.dispose();
    playbackProvider.dispose();
  });

  testWidgets('启用且有列表：渲染推荐卡（歌名/歌手常显），点卡即从该首起播', (tester) async {
    await pumpProvider();
    await provider.grantConsent();
    await provider.setEnabled(true);
    expect(provider.hasRecommendations, isTrue);

    await pumpCarousel(tester);

    expect(find.byKey(const Key('aiDjCarousel')), findsOneWidget);
    expect(find.text('Song 0'), findsOneWidget);
    // 歌名与歌手是 carousel 原生槽位：每张卡都保留。
    expect(find.text('Artist'), findsWidgets);

    await tester.tap(find.text('Song 1'));
    await tester.pumpAndSettle();

    expect(provider.status, AiDjStatus.playing);
    expect(backend.lastRequest?.tracks.first.title, 'Song 0');
    expect(backend.lastRequest?.startIndex, 1);
  });

  testWidgets('滑到末尾只剩「换一批」图标（无文字），点击触发重新生成', (tester) async {
    await pumpProvider();
    await provider.grantConsent();
    await provider.setEnabled(true);
    generator.batchFactory = () => _batch(9, 3);

    await pumpCarousel(tester);
    final callsBefore = generator.calls;

    // 末尾卡只有刷新图标：先滑到末尾让它进入视口，再点图标本身。
    for (var i = 0; i < 6; i++) {
      await tester.fling(
        find.byKey(const Key('aiDjCarousel')),
        const Offset(-400, 0),
        1200,
      );
      await tester.pumpAndSettle();
    }
    expect(find.text('New batch'), findsNothing);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pumpAndSettle();

    expect(generator.calls, greaterThan(callsBefore));
    expect(provider.recommendations?.items.first.track.id.id, '9');
  });

  testWidgets('启用但列表为空：显示生成引导卡，点击生成', (tester) async {
    await pumpProvider();
    // 未确认隐私 → 启用不触发生成（列表为空、无错误）。
    await provider.setEnabled(true);
    expect(provider.hasRecommendations, isFalse);
    expect(provider.lastError, isNull);

    await pumpCarousel(tester);

    expect(find.byKey(const Key('aiDjGenerateCard')), findsOneWidget);
    final callsBefore = generator.calls;

    await tester.tap(find.byKey(const Key('aiDjGenerateCard')));
    await tester.pumpAndSettle();

    expect(generator.calls, greaterThan(callsBefore));
    expect(provider.hasRecommendations, isTrue);
  });

  testWidgets('生成中：保留当前轮播 + 阶段副标题 + 细进度条', (tester) async {
    await pumpProvider();
    await provider.grantConsent();
    await provider.setEnabled(true);
    await pumpCarousel(tester);
    expect(find.byKey(const Key('aiDjCarousel')), findsOneWidget);

    generator.emitProgress = true;
    final gate = Completer<void>();
    generator.gate = gate;
    unawaited(provider.refreshRecommendations());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('aiDjCarousel')), findsOneWidget);
    expect(find.byKey(const Key('aiDjPulsingSkeleton')), findsNothing,
        reason: '已有列表不打断浏览');
    expect(find.textContaining('Finding songs'), findsOneWidget);
    expect(find.byType(AiDjThinProgress), findsOneWidget);
    expect(find.text('Song 0'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('静默自动补歌不切换 active：轮播仍显示原批次', (tester) async {
    generator.batchFactory = () => _batch(0, 20);
    await pumpProvider();
    await provider.grantConsent();
    await provider.setEnabled(true);
    await pumpCarousel(tester);
    final activeId = provider.activeBatchId;
    await provider.startRadio();
    backend.emit(BackendSnapshot(
      current: Track(
        id: const TrackId('wy', '16'),
        title: 'Song 16',
        artists: const [Artist(name: 'Artist')],
        origin: TrackOrigin.builtin,
      ),
      queue: [
        for (var i = 0; i < 20; i++)
          Track(
            id: TrackId('wy', '$i'),
            title: 'Song $i',
            artists: const [Artist(name: 'Artist')],
            origin: TrackOrigin.builtin,
          ),
      ],
      currentIndex: 16,
      isPlaying: true,
      context: const PlaybackContext(name: kAiDjContextName, uri: 'lx:ai'),
    ));
    generator.batchFactory = () => _batch(20, 20);
    provider.onPlaybackChanged();
    await tester.pumpAndSettle();

    expect(provider.activeBatchId, activeId);
    expect(provider.historyEntries.first.origin, AiDjOrigin.autoFeed);
    expect(find.text('Song 0'), findsOneWidget);
    expect(find.text('Song 20'), findsNothing);
    expect(find.textContaining('Auto'), findsNothing, reason: '不展示自动补歌提示');
    // 播放状态节流器还有一帧定时器，等它收尾再结束用例。
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('生成失败：展示重试卡，点击触发重新生成', (tester) async {
    await pumpProvider();
    await provider.grantConsent();
    generator.batchFactory = () => AiDjBatch(
          items: const [],
          generatedAt: DateTime.now(),
        );
    await provider.setEnabled(true);
    expect(provider.lastError, isNotNull);

    await pumpCarousel(tester);

    expect(find.byKey(const Key('aiDjBatchErrorCard')), findsOneWidget);
    final callsBefore = generator.calls;
    generator.batchFactory = () => _batch(0, 3);

    await tester.tap(find.byKey(const Key('aiDjBatchErrorCard')));
    await tester.pumpAndSettle();

    expect(generator.calls, greaterThan(callsBefore));
    expect(provider.hasRecommendations, isTrue);
  });

  testWidgets('功能未启用：即使有列表缓存也整条隐藏', (tester) async {
    await pumpProvider();
    await provider.grantConsent();
    await provider.setEnabled(true);
    expect(provider.hasRecommendations, isTrue);
    await provider.setEnabled(false);

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

  // ── 桌面增强（鼠标拖动 / 滚轮翻卡 / 点卡对位 / 信息区）─────────────────
  //
  // contained 布局同时显示 3 张卡（可翻张数 = 卡数 − 3），因此桌面用例用
  // 6 首的批次：拖动与滚轮才有可翻的空间。

  /// 桌面用例的推荐列表（6 首 = 6 张歌曲卡 + 「换一批」卡）。
  AiDjBatch desktopBatch() => _batch(0, 6);

  /// 信息区当前展示的推荐理由（信息区只显示理由，歌名 / 歌手由卡片承担）。
  Finder reasonOf(int i) => find.text('Reason $i');

  testWidgets('桌面：鼠标拖动卡片流，信息区跟随焦点换卡', (tester) async {
    generator.batchFactory = desktopBatch;
    await pumpProvider();
    await provider.grantConsent();
    await provider.setEnabled(true);

    await pumpCarousel(tester);

    // 初始焦点是首卡：信息区显示首张的理由。
    expect(find.byKey(const Key('aiDjReasonPanel')), findsOneWidget);
    expect(reasonOf(0), findsOneWidget);

    // 鼠标拖动（桌面才放开 dragDevices）：松手吸附到下一张。
    await tester.drag(
      find.byKey(const Key('aiDjCarousel')),
      const Offset(-500, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(reasonOf(0), findsNothing);
    expect(reasonOf(1), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('桌面：滚轮翻卡（未到阈值不翻、到阈值翻一张）', (tester) async {
    generator.batchFactory = desktopBatch;
    await pumpProvider();
    await provider.grantConsent();
    await provider.setEnabled(true);

    await pumpCarousel(tester);
    expect(find.text('Reason 0'), findsOneWidget);

    final center = tester.getCenter(find.byKey(const Key('aiDjCarousel')));

    // 首卡再向上翻：没有上一张可翻，滚轮不生效（这次滚动留给外层页面）。
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, -60)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Reason 0'), findsOneWidget);

    // 单次位移不足阈值：只累计，不翻卡。
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, 20)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Reason 0'), findsOneWidget);
    expect(find.text('Reason 1'), findsNothing);

    // 累计越过阈值：翻到下一张。
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, 25)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Reason 1'), findsOneWidget);
    expect(find.text('Reason 0'), findsNothing);

    // 反向滚轮翻回上一张。
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, -60)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Reason 0'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('桌面：点卡起播并把该卡移到焦点位，信息区换到该卡', (tester) async {
    generator.batchFactory = desktopBatch;
    await pumpProvider();
    await provider.grantConsent();
    await provider.setEnabled(true);

    await pumpCarousel(tester);
    expect(find.text('Reason 0'), findsOneWidget);

    await tester.tap(find.text('Song 1'));
    await tester.pumpAndSettle();

    // 起播该首（队列仍从列表头开始，起始索引是点中的那张）。
    expect(provider.status, AiDjStatus.playing);
    expect(backend.lastRequest?.tracks.first.title, 'Song 0');
    expect(backend.lastRequest?.startIndex, 1);
    // 点中的卡滚到焦点位：信息区跟着落到它身上。
    expect(find.text('Reason 1'), findsOneWidget);
    expect(find.text('Reason 0'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('焦点卡没有推荐理由：信息区整块不渲染', (tester) async {
    generator.batchFactory = () => AiDjBatch(
          items: [
            for (var i = 0; i < 3; i++)
              ResolvedRecommendation(
                source: AiRecommendation(
                  title: 'Song $i',
                  artist: 'Artist',
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
          generatedAt: DateTime.now(),
        );
    await pumpProvider();
    await provider.grantConsent();
    await provider.setEnabled(true);

    await pumpCarousel(tester);

    // 卡片流照常，信息区不留空块。
    expect(find.byKey(const Key('aiDjCarousel')), findsOneWidget);
    expect(find.text('Song 0'), findsOneWidget);
    expect(find.byKey(const Key('aiDjReasonPanel')), findsNothing);
  });

  testWidgets('点「查看全部」打开 AI 页：弹层顶部不再有关闭按钮', (tester) async {
    await pumpProvider();
    await provider.grantConsent();
    await provider.setEnabled(true);

    await pumpCarousel(tester);

    await tester.tap(find.byKey(const Key('aiDjManageButton')));
    await tester.pumpAndSettle();

    expect(find.byType(AiDjPage), findsOneWidget);
    // 弹层 chrome 的 X 已去掉：关闭走遮罩 / Esc / 系统返回。
    expect(find.byIcon(Icons.close_rounded), findsNothing);
  });

  testWidgets('发现页搜索 tab：AI 推歌开启后空占位让位给推荐流', (tester) async {
    await pumpProvider();
    final search = SearchProvider(playbackProvider);
    addTearDown(search.dispose);

    Future<void> pumpTab() async {
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
            ChangeNotifierProvider<LibraryProvider>.value(
                value: libraryProvider),
            ChangeNotifierProvider<SearchProvider>.value(value: search),
          ],
          child: M3EMaterialApp(
            data: M3EThemeData.fromMaterial(ThemeData()),
            theme: ThemeData(),
            locale: const Locale('zh'),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            supportedLocales: const [Locale('zh')],
            home: const Scaffold(body: LibrarySearchTab()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // 未开启：保留「输入关键词搜索歌曲」占位，推荐流不出现。
    await pumpTab();
    expect(find.text('输入关键词搜索歌曲'), findsOneWidget);
    expect(find.byKey(const Key('aiDjGenerateCard')), findsNothing);

    // 开启：占位让位给推荐流（空列表时是「生成推荐」引导卡）。
    await provider.setEnabled(true);
    await tester.pumpAndSettle();
    expect(find.text('输入关键词搜索歌曲'), findsNothing);
    expect(find.byKey(const Key('aiDjGenerateCard')), findsOneWidget);

    // 关闭：占位回来。
    await provider.setEnabled(false);
    await tester.pumpAndSettle();
    expect(find.text('输入关键词搜索歌曲'), findsOneWidget);
    expect(find.byKey(const Key('aiDjGenerateCard')), findsNothing);
  });
}
