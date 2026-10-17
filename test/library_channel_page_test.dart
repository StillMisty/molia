import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/source.dart' as domain;
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/domain/ports/source_registry.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/library.dart';
import 'package:molia/providers/discover_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/sources/lx/lx_engine.dart';
import 'package:molia/sources/lx/lx_engine_supervisor.dart';
import 'package:molia/sources/lx/lx_engine_types.dart';
import 'package:molia/sources/lx/lx_script_info.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:molia/widgets/discover_playlists_tab.dart';
import 'package:molia/widgets/library_channel_selector.dart';
import 'package:molia/widgets/shell_reselect.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_discover_api.dart';
import 'support/fake_library_repository.dart';
import 'support/fakes.dart';

/// 资料页统一渠道测试：渠道下拉框 + tab 显隐 + 搜索源跟随。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLibraryRepository repository;
  late FakePlaybackBackend backend;
  late PlaybackProvider playback;
  late LibraryProvider library;
  late DiscoverProvider discover;
  late SearchProvider search;
  late SourceManager manager;
  late SourcesProvider sources;
  late FakeDiscoverSource wyDiscover;
  late _FakeLxEngine engine;
  late LxEngineSupervisor supervisor;
  bool scriptActive = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = FakeLibraryRepository();
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(
      backend: backend,
      libraryRepository: repository,
    );
    library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    wyDiscover = FakeDiscoverSource();
    discover = DiscoverProvider(
      playbackProvider: playback,
      libraryProvider: library,
      sources: {
        'wy': wyDiscover,
        for (final key in const ['tx', 'kg', 'kw', 'mg'])
          key: FakeDiscoverSource(sourceKey: key),
      },
      // 与 composition root 相同的跟随规则：可搜索渠道 → 搜索源跟随。
      onChannelChanged: (key) {
        if (search.sourceOptions
            .any((option) => option.key == key && option.canSearch)) {
          search.selectSource(key);
        }
      },
    );
    engine = _FakeLxEngine();
    supervisor = LxEngineSupervisor(
      engineFactory: () => engine,
      restartDelays: const [Duration(milliseconds: 10)],
    );
    manager = SourceManager(engine: supervisor);
    sources = SourcesProvider(manager);
    scriptActive = false;
  });

  tearDown(() async {
    sources.dispose();
    manager.dispose();
    await supervisor.close();
    discover.dispose();
    library.dispose();
    playback.dispose();
    await repository.dispose();
  });

  SearchProvider buildSearch(List<domain.SourceDescriptor> descs) {
    final registry = _FakeRegistry(descs);
    final provider = SearchProvider(
      playback,
      sourceRegistry: registry,
    );
    addTearDown(provider.dispose);
    return provider;
  }

  Future<void> activateScript(
    WidgetTester tester, {
    Map<String, LxSourceDecl>? sources,
  }) async {
    engine.nextSources = sources ??
        {
          'test': const LxSourceDecl(
            key: 'test',
            name: '测试源',
            actions: ['musicUrl', 'search'],
            qualitys: ['320k'],
          ),
        };
    // path_provider 在 testWidgets 的 fake-async 下不会返回，必须在 runAsync
    // 的真实事件循环里完成 init / 激活（与 sources_page_menu_dialog_test 一致）。
    await tester.runAsync(() async {
      await manager.init();
      await manager.importScript(
        '/**\n * @name 资料页测试音源\n * @version 1.0.0\n */\n',
        activate: true,
      );
    });
    scriptActive = true;
  }

  Future<void> pumpLibrary(
    WidgetTester tester, {
    ShellReselectSignal? reselect,
    double width = 1200,
  }) async {
    tester.view.physicalSize = Size(width, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SourcesProvider>.value(value: sources),
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          ChangeNotifierProvider<LibraryProvider>.value(value: library),
          ChangeNotifierProvider<DiscoverProvider>.value(value: discover),
          ChangeNotifierProvider<SearchProvider>.value(value: search),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(body: Library(reselect: reselect)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('无脚本：渠道下拉 + 热榜/歌单 tab；搜索 tab 自动隐藏', (tester) async {
    search = buildSearch(const []);
    await pumpLibrary(tester);

    expect(find.byType(LibraryChannelSelector), findsOneWidget);
    expect(find.text('网易音乐'), findsOneWidget); // 渠道下拉当前值
    expect(find.text('热榜'), findsWidgets);
    expect(find.text('歌单'), findsOneWidget);
    expect(find.text('搜索'), findsNothing); // 无脚本时不可搜索 → 隐藏

    // 下拉切换渠道 → 歌单 tab 重新加载。
    await tester.tap(find.text('网易音乐'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('酷我音乐').last);
    await tester.pumpAndSettle();

    expect(discover.channelKey, 'kw');
    expect(find.text('酷我音乐'), findsOneWidget);
  });

  testWidgets('重复点击资料库：当前 tab 列表回到顶部', (tester) async {
    // 歌单 tab 注入多页数据，列表可滚。
    wyDiscover.playlistsPerPage = 40;
    wyDiscover.playlistPages = 1;
    search = buildSearch(const []);
    final reselect = ShellReselectSignal();
    addTearDown(reselect.dispose);
    await pumpLibrary(tester, reselect: reselect);

    // 无脚本：可见 tab = 热榜 / 歌单（默认渲染热榜）。切到歌单。
    await tester.tap(find.text('歌单'));
    await tester.pumpAndSettle();

    final controller = tester
        .widget<Scrollbar>(find.descendant(
          of: find.byType(DiscoverPlaylistsTab),
          matching: find.byType(Scrollbar),
        ))
        .controller!;
    await tester.drag(find.byType(DiscoverPlaylistsTab), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0), reason: '先滚离顶部');

    // 底栏重复点击「资料库」→ 当前（歌单）列表回到顶部。
    reselect.trigger();
    await tester.pumpAndSettle();
    expect(controller.offset, 0, reason: '壳层重复点击应回到顶部');
  });

  testWidgets('全部渠道停用：展示空态引导', (tester) async {
    search = buildSearch(const []);
    await pumpLibrary(tester);

    for (final key in ['wy', 'tx', 'kg', 'kw', 'mg']) {
      await manager.setChannelEnabled(key, false);
    }
    await tester.pumpAndSettle();

    expect(find.text('所有渠道都已停用，请在「音源管理」中启用渠道。'), findsOneWidget);
    expect(find.byType(LibraryChannelSelector), findsNothing);
  });

  testWidgets('选中脚本扩展渠道：只保留搜索 tab；切回内置平台恢复', (tester) async {
    await activateScript(tester);
    expect(scriptActive, isTrue);
    search = buildSearch(const []);
    await pumpLibrary(tester);

    expect(find.text('热榜'), findsWidgets); // 默认 wy（可发现）→ 热榜/歌单

    await tester.tap(find.text('网易音乐'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试源').last);
    await tester.pumpAndSettle();

    expect(discover.channelKey, 'test');
    expect(find.text('热榜'), findsNothing);
    expect(find.text('歌单'), findsNothing);
    // 只剩搜索一个 tab 时不渲染 tab 栏，直接显示搜索内容。
    expect(find.text('输入关键词搜索歌曲'), findsOneWidget);

    // 切回内置平台恢复热榜/歌单。
    await tester.tap(find.text('测试源').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('网易音乐').last);
    await tester.pumpAndSettle();

    expect(discover.channelKey, 'wy');
    expect(find.text('热榜'), findsWidgets);
  });

  testWidgets('搜索源跟随渠道：挂载时将搜索源同步到当前渠道', (tester) async {
    await activateScript(tester, sources: {
      'wy': const LxSourceDecl(
        key: 'wy',
        name: '网易音乐',
        actions: ['musicUrl', 'search'],
        qualitys: ['320k'],
      ),
    });
    search = buildSearch(const [
      domain.SourceDescriptor(
        key: 'tx',
        displayName: 'QQ音乐',
        kind: domain.SourceKind.builtin,
        capabilities: domain.SourceCapabilities(search: true),
      ),
      domain.SourceDescriptor(
        key: 'wy',
        displayName: '网易音乐',
        kind: domain.SourceKind.builtin,
        capabilities: domain.SourceCapabilities(search: true),
      ),
    ]);
    expect(search.sourceKey, 'tx'); // 注册表顺序默认第一个

    await pumpLibrary(tester);

    expect(search.sourceKey, 'wy'); // 已同步到渠道 wy
  });

  testWidgets(
    '桌面宽屏：渠道收进左栏，顶部下拉框不再渲染',
    (tester) async {
      search = buildSearch(const []);
      await pumpLibrary(tester);

      expect(find.byType(LibraryChannelRail), findsOneWidget);
      expect(find.byType(LibraryChannelSelector), findsNothing);
      expect(find.text('网易音乐'), findsOneWidget, reason: '左栏列出全部启用渠道');

      // 左栏点击 = 现有渠道选择路径（含组合根注入的搜索源跟随）。
      await tester.tap(find.text('酷我音乐'));
      await tester.pumpAndSettle();
      expect(discover.channelKey, 'kw');
    },
    // 平台覆盖走 variant：测试体结束后框架自己还原，满足 foundation 变量
    // 不变式（手工覆盖必须在测试体内复位）。
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    '桌面窄窗口：回落顶部下拉框，无渠道左栏',
    (tester) async {
      search = buildSearch(const []);
      await pumpLibrary(tester, width: 800);

      expect(find.byType(LibraryChannelRail), findsNothing);
      expect(find.byType(LibraryChannelSelector), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}

/// 只暴露描述列表的假注册表（搜索源选择用）。
class _FakeRegistry implements SourceRegistry {
  _FakeRegistry(this._descriptors);

  final List<domain.SourceDescriptor> _descriptors;

  @override
  List<domain.SourceDescriptor> get descriptors => _descriptors;

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

/// 可编程 fake 引擎：向管理器提供预设的源声明（不执行真实 JS）。
class _FakeLxEngine implements LxEngine {
  bool running = false;
  Map<String, LxSourceDecl> nextSources = {};

  final StreamController<LxLogEntry> _logs =
      StreamController<LxLogEntry>.broadcast();
  final StreamController<LxUpdateAlert> _alerts =
      StreamController<LxUpdateAlert>.broadcast();
  Map<String, LxSourceDecl> _sources = {};
  LxScriptInfo? _script;

  @override
  bool get isRunning => running;

  @override
  Stream<LxLogEntry> get logs => _logs.stream;

  @override
  Stream<LxUpdateAlert> get updateAlerts => _alerts.stream;

  @override
  Map<String, LxSourceDecl> get sources => Map.unmodifiable(_sources);

  @override
  LxScriptInfo? get script => _script;

  @override
  Future<Map<String, LxSourceDecl>> start(
    LxScriptInfo script, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _script = script;
    _sources = Map<String, LxSourceDecl>.from(nextSources);
    running = true;
    return Map<String, LxSourceDecl>.from(_sources);
  }

  @override
  Future<String> getMusicUrl({
    required String source,
    required Map<String, dynamic> musicInfo,
    required String quality,
    Duration timeout = const Duration(seconds: 20),
  }) async =>
      'https://example.com/$source/$quality';

  @override
  Future<LxLyricResult> getLyric({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 20),
  }) async =>
      const LxLyricResult(lyric: '[00:00.00]fake');

  @override
  Future<String> getPic({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 15),
  }) async =>
      'https://example.com/pic.jpg';

  @override
  Future<dynamic> search({
    required String source,
    required String action,
    required String keyword,
    int page = 1,
    int limit = 20,
    Duration timeout = const Duration(seconds: 20),
  }) async =>
      const [];

  @override
  Future<void> dispose() async {
    running = false;
  }

  @override
  Future<void> close() async {
    running = false;
    if (!_logs.isClosed) await _logs.close();
    if (!_alerts.isClosed) await _alerts.close();
  }
}
