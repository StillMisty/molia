import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/domain/ports/source_registry.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/ai_dj_preferences_page.dart';
import 'package:molia/providers/ai_dj_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/ai/ai_settings_store.dart';

import 'support/fake_ai_generator.dart';
import 'support/fake_library_repository.dart';
import 'support/fakes.dart';
import 'support/settings_test_support.dart';

class _FakeRegistry implements SourceRegistry {
  @override
  List<SourceDescriptor> get descriptors => const [
        SourceDescriptor(
          key: 'wy',
          displayName: 'NetEase',
          kind: SourceKind.builtin,
          capabilities: SourceCapabilities(search: true),
          order: 1,
        ),
        SourceDescriptor(
          key: 'tx',
          displayName: 'QQ Music',
          kind: SourceKind.builtin,
          capabilities: SourceCapabilities(search: true),
          order: 2,
        ),
        SourceDescriptor(
          key: 'off',
          displayName: 'Disabled',
          kind: SourceKind.builtin,
          capabilities: SourceCapabilities(search: true),
          enabled: false,
          order: 3,
        ),
      ];

  @override
  MusicSource? byKey(String key) => null;

  @override
  MusicSource? forTrack(Track track) => null;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> setOrder(List<String> keys) async {}

  @override
  Stream<void> get changes => const Stream.empty();
}

AiDjBatch _emptyBatch() =>
    AiDjBatch(items: const [], generatedAt: DateTime.now());

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
      sourceRegistry: _FakeRegistry(),
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
          home: const AiDjPreferencesPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder switchIn(Key row) => find.descendant(
        of: find.byKey(row),
        matching: find.byType(M3ESwitch),
      );

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
    generator = FakeAiDjGenerator(batchFactory: _emptyBatch);
    await pumpProvider();
  });

  tearDown(() {
    provider.dispose();
    libraryProvider.dispose();
    playbackProvider.dispose();
  });

  testWidgets('默认值：批次 20 / 自动补歌开 / 只推没听过的开 / 收藏歌单关', (tester) async {
    await pumpPage(tester);

    expect(find.text('Recommendation preferences'), findsOneWidget);
    expect(find.text('20 per batch'), findsOneWidget);
    expect(
      tester
          .widget<M3ESwitch>(switchIn(const Key('aiDjPrefAutoFeedSwitch')))
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<M3ESwitch>(switchIn(const Key('aiDjPrefOnlyUnheardSwitch')))
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<M3ESwitch>(switchIn(const Key('aiDjPrefScope_favorites')))
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<M3ESwitch>(switchIn(const Key('aiDjPrefScope_playlists')))
          .value,
      isFalse,
    );
    // 可搜索渠道只显示启用的两个（停用的不出现）。
    expect(find.byKey(const Key('aiDjPrefChannel_wy')), findsOneWidget);
    expect(find.byKey(const Key('aiDjPrefChannel_tx')), findsOneWidget);
    expect(find.byKey(const Key('aiDjPrefChannel_off')), findsNothing);
  });

  testWidgets('本地草稿：保存前不写 provider，保存不触发生成', (tester) async {
    final callsBefore = generator.calls;
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('aiDjPrefOption_pop')));
    await tester.tap(find.byKey(const Key('aiDjPrefChannel_tx')));
    await tester.enterText(
      find.byKey(const Key('aiDjPrefExtraField')),
      '想听女声',
    );
    await tester.pump();

    expect(provider.preferences.styles, isEmpty);
    expect(provider.preferences.sourceKeys, isEmpty);
    expect(provider.preferences.extraPrompt, isEmpty);

    await tester.tap(find.byKey(const Key('aiDjPrefsSaveButton')));
    await tester.pumpAndSettle();

    expect(provider.preferences.styles, ['pop']);
    expect(provider.preferences.sourceKeys, ['tx']);
    expect(provider.preferences.extraPrompt, '想听女声');
    expect(generator.calls, callsBefore, reason: '保存偏好不生成');
    expect(
      find.text('Saved — applies to the next batch'),
      findsOneWidget,
    );
  });

  testWidgets('批次大小 / 自动补歌 / 只推荐没听过的 / 探索度', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('aiDjPrefBatchSizeDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 per batch').last);
    await tester.pumpAndSettle();

    await tester.tap(switchIn(const Key('aiDjPrefAutoFeedSwitch')));
    await tester.tap(switchIn(const Key('aiDjPrefOnlyUnheardSwitch')));
    await tester.tap(find.byKey(const Key('aiDjPrefOption_surprise')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('aiDjPrefsSaveButton')));
    await tester.pumpAndSettle();

    expect(provider.preferences.batchSize, 30);
    expect(provider.preferences.autoFeed, isFalse);
    expect(provider.preferences.onlyUnheard, isFalse);
    expect(provider.preferences.exploration, kAiExplorationSurprise);
  });

  testWidgets('收藏首次开启：提示读取歌名与歌手，确认后保存发送范围', (tester) async {
    await pumpPage(tester);

    await tester.tap(switchIn(const Key('aiDjPrefScope_favorites')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('reads the titles and artists'),
      findsOneWidget,
    );
    expect(provider.preferences.sections.contains(AiUpstreamSection.favorites),
        isFalse);

    await tester.tap(find.byKey(const Key('aiDjScopeConfirm_favorites')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('aiDjPrefsSaveButton')));
    await tester.pumpAndSettle();

    expect(provider.preferences.sections.contains(AiUpstreamSection.favorites),
        isTrue);
    expect(
      provider.preferences.acknowledgedScopes,
      contains(AiUpstreamSection.favorites),
    );

    // 再次关闭再开启不应重复弹提示。
    await tester.tap(switchIn(const Key('aiDjPrefScope_favorites')));
    await tester.pump();
    await tester.tap(switchIn(const Key('aiDjPrefScope_favorites')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('reads the titles and artists'),
      findsNothing,
    );
    expect(provider.preferences.sections.contains(AiUpstreamSection.favorites),
        isTrue);
  });

  testWidgets('渠道：选中后按音源页顺序保存；种子可删除', (tester) async {
    await provider.addSeed('晴天 - 周杰伦');
    await pumpPage(tester);

    expect(find.text('More like · 晴天 - 周杰伦'), findsOneWidget);

    await tester.tap(find.byKey(const Key('aiDjPrefChannel_tx')));
    await tester.tap(find.byKey(const Key('aiDjPrefChannel_wy')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('aiDjPrefsSaveButton')));
    await tester.pumpAndSettle();

    expect(provider.preferences.sourceKeys, ['wy', 'tx']);

    await tester.tap(find.byIcon(M3EIcons.close).last);
    await tester.pumpAndSettle();
    expect(provider.seeds, isEmpty);
  });

  testWidgets('所选渠道全部不可用时显示回退提示', (tester) async {
    await provider.savePreferences(
      provider.preferences.copyWith(sourceKeys: ['off']),
    );
    await pumpPage(tester);

    expect(
      find.text(
          'Selected sources are unavailable right now; auto sources are used instead'),
      findsOneWidget,
    );
  });

  testWidgets('恢复默认：确认后重置并保存', (tester) async {
    await provider.savePreferences(
      provider.preferences.copyWith(
        batchSize: 50,
        autoFeed: false,
        styles: ['rock'],
        sourceKeys: ['tx'],
        sections: {
          ...kAiDefaultUpstreamSections,
          AiUpstreamSection.favorites,
        },
      ),
    );
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('aiDjPrefsResetButton')));
    await tester.pumpAndSettle();
    expect(find.text('Restore default preferences?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('aiDjPrefsResetConfirm')));
    await tester.pumpAndSettle();

    expect(provider.preferences, isA<AiPreferences>());
    expect(provider.preferences.batchSize, 20);
    expect(provider.preferences.autoFeed, isTrue);
    expect(provider.preferences.styles, isEmpty);
    expect(provider.preferences.sourceKeys, isEmpty);
    expect(provider.preferences.sections, kAiDefaultUpstreamSections);
    expect(find.text('Default preferences restored'), findsOneWidget);
  });
}
