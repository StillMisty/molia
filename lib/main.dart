import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

import 'data/catalog/catalog_service.dart';
import 'data/catalog/source_registry_impl.dart';
import 'data/library_repository.dart';
import 'data/playback/default_playback_facade.dart';
import 'data/playback/local_playback_backend.dart';
import 'domain/models/failure.dart';
import 'domain/ports/source_registry.dart';
import 'domain/ports/ui_messenger.dart';
import 'l10n/app_localizations.dart';
import 'data/database_factory_init.dart';
import 'pages/favorites.dart';
import 'pages/library.dart';
import 'pages/settings_page.dart';
import 'pages/nowplaying.dart';
import 'playback/desktop_audio_init.dart';
import 'playback/local_audio_handler.dart';
import 'playback/local_playback_service.dart';
import 'providers/library_provider.dart';
import 'providers/local_database_provider.dart';
import 'providers/nav_provider.dart';
import 'providers/playback_provider.dart';
import 'providers/search_provider.dart';
import 'providers/discover_provider.dart';
import 'providers/sources_provider.dart';
import 'providers/theme_provider.dart';
import 'services/app_branding_service.dart';
import 'services/cache_service.dart';
import 'services/language_service.dart';
import 'managers/artwork_cache.dart';
import 'services/data_saver_service.dart';
import 'services/lyrics_service.dart';
import 'services/notification_service.dart';
import 'services/settings_service.dart';
import 'sources/source_manager.dart';
import 'theme/animated_scheme.dart';
import 'theme/app_theme.dart';
import 'utils/responsive.dart';
import 'widgets/app_network_image.dart';
import 'widgets/nav_destination_icons.dart';
import 'widgets/playback_selectors.dart';
import 'widgets/player_morph.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// home 宿主 context：位于 Navigator/Overlay 之下，供 NotificationService
/// 展示 M3ESnackbar（ScaffoldMessenger 的 context 在 Overlay 之上不可用）。
final GlobalKey appRootKey = GlobalKey(debugLabel: 'appRoot');
final logger = Logger();

/// composition root 内的 UiMessenger 适配器：唯一持有 navigatorKey /
/// scaffoldMessengerKey 的提示出口，把领域失败映射为 l10n 文案。
///
/// provider 不再 import main.dart，错误提示统一经此注入（docs/architecture.md §2.1）。
class _AppUiMessenger implements UiMessenger {
  const _AppUiMessenger(this._notifications);

  final NotificationService _notifications;

  @override
  void showMessage(String message) {
    _notifications.showSnackBar(message, duration: const Duration(seconds: 3));
  }

  @override
  void showFailure(SourceFailure failure) {
    final context = navigatorKey.currentContext;
    final l10n = context == null ? null : AppLocalizations.of(context);
    final text =
        l10n == null ? '播放失败: ${failure.message}' : _localize(l10n, failure);
    _notifications.showSnackBar(text, duration: const Duration(seconds: 3));
  }

  /// 把领域失败映射为 l10n 文案：参数化键（playbackFailed 等）按
  /// failure.l10nKey 分发，未知 key 回退通用播放失败文案。
  String _localize(AppLocalizations l10n, SourceFailure failure) {
    switch (failure.l10nKey) {
      case null:
      case 'playbackFailed':
        return l10n.playbackFailed(failure.message);
      default:
        // 未知 key 回退到通用播放失败文案（不显示 `$e` 之外的新格式）。
        return l10n.playbackFailed(failure.message);
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面端（Linux/Windows）初始化 sqflite FFI，保证本地笔记数据库可用
  initDatabaseFactoryIfNeeded();

  // 桌面端本地播放后端（Windows/Linux: media_kit）
  initDesktopAudioIfNeeded();

  final sourceManager = SourceManager();

  // 省流模式（仅移动数据生效）：必须在解析/播放/封面链路创建前就绪，
  // 供取链回调、封面网关与播放 provider 共享同一实例。
  final dataSaver = DataSaverService();
  await dataSaver.init();
  // 封面统一咽喉：省流生效时只用本地缓存，不发网络请求
  // （AppNetworkImage / artworkImageProvider / 取色共用）。
  ArtworkCache.instance.networkImageBlocked =
      () => dataSaver.blockNetworkArtwork;

  // 适配层：SourceManager → SourceRegistry → CatalogService。
  // SearchProvider 只依赖后两者（搜索缓存 single-flight + LRU + TTL 5min）。
  final sourceRegistry = SourceRegistryImpl(sourceManager);
  final catalogService = CatalogService(registry: sourceRegistry);

  // 本地播放后端：backend 持有领域解析器端口（Track → PlayableStream），
  // 服务的解析回调 late 绑定到 backend；resolver 走 CatalogService.resolve
  // （single-flight + LRU + 10min TTL），重播/循环播放命中缓存。
  late final LocalPlaybackBackend playbackBackend;
  final localPlayback = LocalPlaybackService(
    // 由服务按实际选择的音质调用解析器（同一音质也用于音频缓存键）。
    // 省流上限只在 preferredQuality 一处压低：resolve 缓存键包含真实音质
    // 维度，切换网络后自然重解析。
    preferredQuality: () =>
        dataSaver.effectiveQuality(sourceManager.preferredQuality),
    resolver: (track, {String? quality}) =>
        playbackBackend.resolveLegacyUrl(track, quality: quality),
  );
  playbackBackend = LocalPlaybackBackend(
    service: localPlayback,
    resolver: (track, quality) =>
        catalogService.resolve(track, quality: quality),
  );
  final playbackFacade = DefaultPlaybackFacade(backend: playbackBackend);

  // 本地播放服务在 main 中创建：系统媒体会话（audio_service）需在 runApp
  // 之前初始化，并复用同一个 LocalPlaybackService 实例。
  // 不支持 audio_service 的平台（Linux/Windows/Web）返回 null，自动降级。
  // 省流时通知/锁屏封面置空，避免 audio_service 为通知下载封面。
  await initSystemMediaSession(
    localPlayback,
    artworkBlocked: () => dataSaver.blockNetworkArtwork,
  );

  // 唯一 composition root：PlaybackProvider 不再 import main.dart，
  // 错误提示（UiMessenger）与写库/预加载所需 Context 在此注入。
  // NotificationService 提前创建：UiMessenger 与 Provider 共用同一实例。
  final notificationService = NotificationService(
    scaffoldMessengerKey,
    hostContextKey: appRootKey,
  );
  // 资料库仓库：播放历史 / 我的列表 / 收藏；播放开始时由
  // PlaybackProvider 写历史，资料库页经 LibraryProvider 读取（内存缓存）。
  final libraryRepository = LibraryRepository();
  // 最近播放上下文（play_contexts）：提前创建，同一实例既进 Provider 树，
  // 也直接注入 PlaybackProvider（不再经 navigatorKey 反查 provider）。
  final localDatabaseProvider = LocalDatabaseProvider();
  final playbackProvider = PlaybackProvider(
    facade: playbackFacade,
    messenger: _AppUiMessenger(notificationService),
    sourceManager: sourceManager,
    navigatorKey: navigatorKey,
    catalogService: catalogService,
    libraryRepository: libraryRepository,
    dataSaver: dataSaver,
    localDatabaseProvider: localDatabaseProvider,
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: sourceManager),
        // 音源管理 UI 门面：订阅同一个 SourceManager，生命周期与其一致
        // （不负责 dispose manager）。
        ChangeNotifierProvider(
          create: (_) => SourcesProvider(sourceManager),
        ),
        Provider<SourceRegistry>.value(value: sourceRegistry),
        Provider<CatalogService>.value(value: catalogService),
        ChangeNotifierProvider.value(value: playbackProvider),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => NavProvider()),
        ChangeNotifierProvider(
          create: (context) => SearchProvider(
            context.read<PlaybackProvider>(),
            catalogService: catalogService,
            sourceRegistry: sourceRegistry,
          ),
        ),
        ChangeNotifierProvider.value(value: localDatabaseProvider),
        ChangeNotifierProvider(
          create: (_) => LibraryProvider(
            repository: libraryRepository,
            playbackProvider: playbackProvider,
          ),
        ),
        // 发现页：热榜 / 歌单 / 热搜；播放与收藏复用上面两个 provider。
        ChangeNotifierProvider(
          create: (context) => DiscoverProvider(
            playbackProvider: context.read<PlaybackProvider>(),
            libraryProvider: context.read<LibraryProvider>(),
          ),
        ),
        Provider<LyricsService>(create: (_) => LyricsService()),
        // 统一缓存门面（音频/歌词/封面）：设置页缓存管理读写策略与用量。
        Provider<CacheService>.value(value: CacheService.instance),
        Provider<NotificationService>.value(value: notificationService),
        Provider<SettingsService>(
            create: (_) => SettingsService()), // Add this line
        // 省流模式：设置页读写开关/音质上限；取链与封面网关已在上方接线。
        ChangeNotifierProvider.value(value: dataSaver),
      ],
      child: const MyThemedApp(),
    ),
  );

  // 启动后初始化音源（加载已导入的 LX 音源脚本）
  WidgetsBinding.instance.addPostFrameCallback((_) {
    sourceManager.init();
  });
}

class MyThemedApp extends StatefulWidget {
  const MyThemedApp({super.key});

  @override
  State<MyThemedApp> createState() => _MyThemedAppState();
}

class _MyThemedAppState extends State<MyThemedApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedLocale();
    // 自定义应用名称（顶栏回退文案）需要重建 MaterialApp.title。
    AppBrandingService.titleNotifier.addListener(_onBrandingChanged);
    AppBrandingService.load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Android 后台不再广播网络变化（Android 8+）：回前台时主动刷新一次，
    // 否则「离开 Wi-Fi 后仍按 Wi-Fi 判定」，省流模式不会按时生效。
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<DataSaverService>().refreshConnectivity();
    }
  }

  void _onBrandingChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppBrandingService.titleNotifier.removeListener(_onBrandingChanged);
    super.dispose();
  }

  Future<void> _loadSavedLocale() async {
    final savedLocale = await LanguageService.getSavedLocale();
    if (savedLocale != null) {
      LanguageService.localeNotifier.value = savedLocale;
    }
  }

  /// 品牌默认名跟随界面语言（en=Molia / zh=茉咏）。
  ///
  /// 只读计算 + 帧末注入：build 阶段直接更新 notifier 会触发
  /// markNeedsBuild 告警；已自定义名称时 applyLocalizedDefault 内部自动忽略。
  void _syncLocalizedBranding(Locale? locale) {
    final effective =
        locale ?? WidgetsBinding.instance.platformDispatcher.locale;
    final resolved = LanguageService.supportedLocales
            .any((supported) => supported.languageCode == effective.languageCode)
        ? effective
        : LanguageService.supportedLocales.first;
    final name = lookupAppLocalizations(resolved).appName;
    if (name == AppBrandingService.defaultTitle) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        AppBrandingService.applyLocalizedDefault(name);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // ThemeProvider（主题模式 + 封面取色 + 莫奈 + 纯黑）是唯一主题来源：
    // Selector 提升到壳外，colorScheme 变化时重建整个 M3EMaterialApp，
    // 同时刷新 material_ui ThemeData 与 M3EThemeData。
    // 应用语言走 LanguageService.localeNotifier，设置页切换后立即生效。
    //
    // 莫奈配色由 DynamicColorBuilder 提供（平台不支持时回调 null）：
    // 注入必须放到 post-frame，避免在 build 中同步触发 notifyListeners。
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          context
              .read<ThemeProvider>()
              .updateMonetSchemes(lightDynamic, darkDynamic);
        });
        return ValueListenableBuilder<Locale?>(
          valueListenable: LanguageService.localeNotifier,
          builder: (context, locale, _) {
            // 品牌默认名随界面语言本地化（Molia / 茉咏）。
            _syncLocalizedBranding(locale);
            return Selector<ThemeProvider, ColorScheme>(
            selector: (context, provider) => provider.colorScheme,
            // 方案色变化（切歌取色/莫奈/种子色/亮度）经 AnimatedSchemeBuilder
            // 平滑过渡，避免整站颜色闪变；只插值 ColorScheme，material_ui 与
            // M3E 两套主题都由同一插值结果重建，保证过渡期一致。
            builder: (context, colorScheme, _) => AnimatedSchemeBuilder(
              scheme: colorScheme,
              builder: (context, animatedScheme) {
                final systemUiOverlayStyle =
                    buildSystemUiOverlayStyle(animatedScheme);
                final themedData = buildAppThemeData(
                  animatedScheme,
                  systemUiOverlayStyle: systemUiOverlayStyle,
                );

                return M3EMaterialApp(
                  title: AppBrandingService.titleNotifier.value,
                  scaffoldMessengerKey: scaffoldMessengerKey,
                  navigatorKey: navigatorKey,
                  locale: locale,
                  // material_ui 的 delegates 已合并 Material/Widgets/Cupertino 三套文案
                  localizationsDelegates: const [
                    AppLocalizations.delegate,
                    ...GlobalMaterialLocalizations.delegates,
                  ],
                  supportedLocales: LanguageService.supportedLocales,
                  // material_ui 透传：既有组件通过 Theme.of 读到的外观保持现状。
                  theme: themedData,
                  darkTheme: themedData,
                  // M3E 侧数据：颜色/字体从 themedData 映射（按 ThemeData 实例缓存）。
                  data: M3EThemeData.fromMaterial(themedData),
                  // 方案色过渡已由 AnimatedSchemeBuilder 逐帧插值完成，
                  // 关掉 MaterialApp 内置主题动画，避免二次缓动造成两套主题不同步。
                  themeAnimationStyle: AnimationStyle.noAnimation,
                  // 系统亮度由 ThemeProvider.updateThemeFromSystem 驱动，
                  // 封面/莫奈取色由 ThemeProvider 内部优先级决定；不启用 M3E
                  // 自适应与 OS 动态色，避免双主题源互相覆盖。
                  autoTheming: false,
                  dynamicColoring: false,
                  // targetSdk 37（Android 15+ 强制 edge-to-edge）下保持系统栏透明、
                  // 内容绘制到系统栏下方，与 settings_page.dart 的 edgeToEdge 行为一致。
                  drawUnderSystemBars: true,
                  // 原 MaterialApp.builder 逻辑迁移到 appBuilder：M3E 内部已用
                  // M3ETheme 包裹 child，MaterialApp 的 Theme 又位于 builder 之上
                  // （见 material_ui app.dart _materialBuilder），因此这里只做
                  // 系统栏 AnnotatedRegion + Web 字号缩放，不再重复包 Theme。
                  appBuilder: (context, child) {
                    final themedChild = child ?? const SizedBox.shrink();
                    final baseMediaQuery = MediaQuery.of(context);
                    final double textScaleMultiplier = kIsWeb ? 1.12 : 1.0;
                    final baseScale = baseMediaQuery.textScaler.scale(1.0);
                    final mediaData = baseMediaQuery.copyWith(
                      textScaler:
                          TextScaler.linear(baseScale * textScaleMultiplier),
                    );

                    return AnnotatedRegion<SystemUiOverlayStyle>(
                      value: systemUiOverlayStyle,
                      child: MediaQuery(
                        data: mediaData,
                        child: themedChild,
                      ),
                    );
                  },
                  home: MyApp(key: appRootKey),
                );
              },
            ),
          );
          },
        );
      },
    );
  }
}

class ProgressIndicator extends StatefulWidget {
  /// 当前进度（来自 provider.position 单一时钟，无自外推）。
  final Duration position;
  final double duration;

  /// 是否正在播放：暂停时用非波浪进度条（波浪动画会一直动，像还在播放）。
  final bool isPlaying;

  const ProgressIndicator({
    super.key,
    required this.position,
    required this.duration,
    this.isPlaying = true,
  });

  @override
  State<ProgressIndicator> createState() => _ProgressIndicatorState();
}

class _ProgressIndicatorState extends State<ProgressIndicator>
    with SingleTickerProviderStateMixin {
  late double _currentProgress;
  late final AnimationController _animationController;
  late Animation<double> _progressAnimation;

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _currentProgress = widget.position.inMilliseconds.toDouble();

    _progressAnimation = Tween<double>(
      begin: _currentProgress,
      end: _currentProgress,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void didUpdateWidget(ProgressIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.position.inMilliseconds.toDouble();
    // 仅 seek/切歌等 >1s 的跳变做 300ms 平滑过渡；
    // 常规推进直接跟随 position 通道（不再有 1s Timer 外推）。
    if ((target - _currentProgress).abs() > 1000) {
      final display = _animationController.isAnimating
          ? _progressAnimation.value
          : _currentProgress;
      _progressAnimation = Tween<double>(
        begin: display,
        end: target,
      ).animate(CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeInOut,
      ));
      _currentProgress = target;
      _animationController.forward(from: 0);
    } else {
      _currentProgress = target;
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progressAnimation,
      builder: (context, child) {
        final displayProgress = _animationController.isAnimating
            ? _progressAnimation.value
            : _currentProgress;
        final double? fraction = widget.duration > 0
            ? (displayProgress / widget.duration).clamp(0.0, 1.0)
            : null;

        // 暂停时切到平直进度条：波浪动画不会停，与暂停状态矛盾。
        return widget.isPlaying
            ? M3EProgressIndicator.linearWavy(
                value: fraction,
                linearSize: M3EProgressIndicatorSize.s,
                strokeWidth: 4.0,
                trackStrokeWidth: 4.0,
                trackColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                color: Theme.of(context).colorScheme.primary,
              )
            : M3EProgressIndicator.linear(
                value: fraction,
                linearSize: M3EProgressIndicatorSize.s,
                strokeWidth: 4.0,
                trackStrokeWidth: 4.0,
                trackColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                color: Theme.of(context).colorScheme.primary,
              );
      },
    );
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  /// 顶栏 ↔ 播放页共享元素飞行控制器。
  final PlayerMorphController _morph = PlayerMorphController();

  /// tab 淡入淡出（fade-through）控制器。
  late final AnimationController _tabTransition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  )..value = 1.0;

  /// 共享元素飞行控制器（前 72% 行程移动，后 28% 与目标端交叉淡出）。
  late final AnimationController _morphAnimation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
  );

  OverlayEntry? _morphEntry;
  PlayerMorphGeometry? _morphGeometry;
  int _morphToken = 0;

  /// 页面实例固定（key 稳定），顺序/显隐只影响底栏映射与分层透明度，
  /// 页面状态（滚动/搜索词等）天然保持。
  late final Map<ShellDestination, Widget> _pages = {
    ShellDestination.nowPlaying: NowPlaying(morph: _morph),
    ShellDestination.favorites: const FavoritesPage(),
    ShellDestination.library: const Library(),
  };

  /// 当前选中的目的地（与底栏顺序解耦；默认落在播放页）。
  ShellDestination _selectedDestination = ShellDestination.nowPlaying;
  ShellDestination _previousDestination = ShellDestination.nowPlaying;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _morphAnimation.addListener(_onMorphTick);
    // 冷启动默认落在播放页：顶栏必须与「手动进入播放页」后的状态一致
    // （收起为应用标识）。否则恢复会话后顶栏会重复显示曲目封面/进度。
    _morph.setBarHeaderHidden(
      _selectedDestination == ShellDestination.nowPlaying,
    );
    // 初始化时更新主题
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ThemeProvider>().updateThemeFromSystem(context);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _morphAnimation.removeListener(_onMorphTick);
    _morphAnimation.dispose();
    _tabTransition.dispose();
    _morphEntry?.remove();
    _morphEntry = null;
    _morph.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 应用从后台恢复时刷新主题
      context.read<ThemeProvider>().updateThemeFromSystem(context);
    }
  }

  @override
  void didChangePlatformBrightness() {
    // 当系统主题改变时更新应用主题
    context.read<ThemeProvider>().updateThemeFromSystem(context);
  }

  void _selectDestination(ShellDestination destination) {
    if (destination == _selectedDestination) return;
    HapticFeedback.lightImpact();
    final leavingPlayer = _selectedDestination == ShellDestination.nowPlaying;
    final enteringPlayer = destination == ShellDestination.nowPlaying;
    setState(() {
      _previousDestination = _selectedDestination;
      _selectedDestination = destination;
    });
    _tabTransition.forward(from: 0);
    if (enteringPlayer) {
      _startMorph(toPage: true);
    } else if (leavingPlayer) {
      _startMorph(toPage: false);
    } else {
      // 两端都不是播放页：不涉及共享元素，确保两端真身可见。
      _morph.setPageHeaderHidden(false);
      _morph.setBarHeaderHidden(false);
    }
  }

  /// 开始一次顶栏 ↔ 播放页飞行；锚点缺失（迷你态/首帧）时优雅跳过。
  void _startMorph({required bool toPage}) {
    _completeMorph();
    final geometry = _morph.captureGeometry(toPage: toPage);
    if (geometry == null) {
      _morph.setPageHeaderHidden(false);
      _morph.setBarHeaderHidden(toPage);
      return;
    }
    _morph.setBarHeaderHidden(true);
    if (toPage) _morph.setPageHeaderHidden(true);
    _morphGeometry = geometry;
    final token = ++_morphToken;
    _morphEntry = OverlayEntry(
      builder: (context) => PlayerMorphFlight(
        animation: _morphAnimation,
        geometry: geometry,
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_morphEntry!);
    _morphAnimation.forward(from: 0).whenComplete(() {
      if (!mounted || token != _morphToken) return;
      _completeMorph();
    });
  }

  /// 飞行到达（[PlayerMorphFlight.flightPortion]）即在同一帧完成交接：
  /// 先亮出目标端真身、再移除飞行副本，两端封面位置完全一致，无尾段闪烁。
  void _onMorphTick() {
    if (_morphGeometry == null) return;
    if (_morphAnimation.value >= PlayerMorphFlight.flightPortion) {
      _completeMorph();
    }
  }

  void _removeMorphOverlay() {
    _morphEntry?.remove();
    _morphEntry = null;
  }

  void _completeMorph() {
    _morphToken++;
    final geometry = _morphGeometry;
    _morphGeometry = null;
    if (geometry == null) {
      _removeMorphOverlay();
      return;
    }
    // 落位：目标端真身瞬时亮出（AnimatedOpacity 的 reveal 方向时长为 0），
    // 同一帧移除飞行副本；播放页激活时顶栏收起（内容由页面承接）。
    _morph.setPageHeaderHidden(false);
    _morph.setBarHeaderHidden(geometry.toPage);
    _removeMorphOverlay();
  }

  String _destinationLabel(
    AppLocalizations l10n,
    ShellDestination destination,
  ) =>
      switch (destination) {
        ShellDestination.nowPlaying => l10n.nowPlayingLabel,
        ShellDestination.favorites => l10n.favoritesLabel,
        ShellDestination.library => l10n.libraryLabel,
      };

  /// 页面分层：选中页在最上层淡入，上一页快速淡出（fade-through）。
  Widget _buildPageStack() {
    final ordered = <ShellDestination>[
      for (final destination in ShellDestination.values)
        if (destination != _selectedDestination) destination,
      _selectedDestination,
    ];
    return Stack(
      children: [
        for (final destination in ordered)
          _ShellPageLayer(
            key: ValueKey(destination),
            selected: destination == _selectedDestination,
            outgoing: destination == _previousDestination &&
                destination != _selectedDestination,
            animation: _tabTransition,
            child: _pages[destination]!,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final shellLayout = context.layoutType(ResponsivePageType.shell);
    final isLargeScreen = shellLayout.preferTwoPane;
    final l10n = AppLocalizations.of(context)!;
    final visibleDestinations =
        context.watch<NavProvider>().visibleDestinations;
    // 选中项被隐藏时回退到第一个可见目的地（重新显示后自动恢复）。
    final selectedDestination = visibleDestinations.isEmpty
        ? _selectedDestination
        : (visibleDestinations.contains(_selectedDestination)
            ? _selectedDestination
            : visibleDestinations.first);
    final selectedIndex = visibleDestinations.indexOf(selectedDestination);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: _ShellBarHeader(morph: _morph),
        actions: [
          const _BarNextButton(),
          M3EIconButton(
            variant: M3EIconButtonVariant.tonal,
            onPressed: () {
              HapticFeedback.lightImpact();
              ResponsiveNavigation.showAdaptiveModalPage(
                context: context,
                showCloseButton: false,
                child: const SettingsPage(),
              );
            },
            tooltip: l10n.settingsTitle,
            icon: const Icon(Icons.settings_rounded),
          ),
          const SizedBox(width: 8),
        ],
        bottom: PreferredSize(
          // 波浪进度条需要振幅空间（M3E 默认 wavyContainerHeight=10）。
          preferredSize: const Size.fromHeight(10.0),
          child: _ShellBarProgress(morph: _morph),
        ),
      ),
      body: Row(
        children: [
          if (isLargeScreen)
            M3ENavigationRail(
              // 固定 96dp 窄轨（alwaysCollapse）：无展开按钮，
              // 保持原 NavigationRail 不可展开的交互语义；标签常显，
              // 替代 Material 侧 hover 才出现的 tooltip。
              type: M3ENavigationRailType.alwaysCollapse,
              selectedIndex: selectedIndex,
              onDestinationSelected: (int index) =>
                  _selectDestination(visibleDestinations[index]),
              sections: [
                M3ENavigationRailSection(
                  destinations: [
                    for (final destination in visibleDestinations)
                      M3ENavigationRailDestination(
                        icon: destination.outlinedIcon,
                        selectedIcon: destination.filledIcon,
                        label: _destinationLabel(l10n, destination),
                      ),
                  ],
                ),
              ],
            ),
          Expanded(child: _buildPageStack()),
        ],
      ),
      bottomNavigationBar: isLargeScreen
          ? null
          : SafeArea(
              bottom: false,
              child: M3ENavigationBar(
                // iOS 使用紧凑高度（Material 侧原为 55，M3E 最小档为 64）
                size: defaultTargetPlatform == TargetPlatform.iOS
                    ? M3ENavBarSize.small
                    : M3ENavBarSize.medium,
                labelBehavior: M3ENavBarLabelBehavior.onlySelected,
                selectedIndex: selectedIndex,
                onDestinationSelected: (int index) =>
                    _selectDestination(visibleDestinations[index]),
                destinations: [
                  for (final destination in visibleDestinations)
                    M3ENavigationBarDestination(
                      icon: destination.outlinedIcon,
                      selectedIcon: destination.filledIcon,
                      label: _destinationLabel(l10n, destination),
                    ),
                ],
              ),
            ),
    );
  }
}

/// 单个 tab 页的分层包装：fade-through（出场快速淡出微缩，入场淡入回落）。
///
/// `child` 为稳定实例：动画每帧只重建包装层，页面子树不重建（状态保持）。
class _ShellPageLayer extends StatelessWidget {
  const _ShellPageLayer({
    super.key,
    required this.selected,
    required this.outgoing,
    required this.animation,
    required this.child,
  });

  final bool selected;
  final bool outgoing;
  final Animation<double> animation;
  final Widget child;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final t = Curves.easeInOutCubic.transform(animation.value);
        final double opacity;
        final double scale;
        if (selected) {
          final inT = Curves.easeOutCubic.transform(
            ((t - 0.15) / 0.85).clamp(0.0, 1.0),
          );
          opacity = inT;
          // 入场不做微缩：共享元素飞行锚点在点击那一刻抓取（localToGlobal 含
          // 祖先变换），任何非 1 的入场缩放都会让副本落在缩放后的位置/尺寸，
          // 交接瞬间真身跳变（这就是「切换时闪动」的来源）。
          scale = 1.0;
        } else if (outgoing) {
          final outT = (t / 0.35).clamp(0.0, 1.0);
          opacity = 1.0 - Curves.easeInCubic.transform(outT);
          scale = _lerp(1.0, 0.97, outT);
        } else {
          opacity = 0.0;
          scale = 1.0;
        }
        return IgnorePointer(
          ignoring: !selected,
          child: TickerMode(
            enabled: selected,
            child: Opacity(
              opacity: opacity,
              child: Transform.scale(scale: scale, child: child),
            ),
          ),
        );
      },
    );
  }
}

/// 顶栏头部：左侧当前曲目封面（无封面回退音符图标），旁边歌名 + 作者。
///
/// 播放页激活（或飞行中）时交叉淡出为应用图标 + 自定义应用名。
class _ShellBarHeader extends StatelessWidget {
  const _ShellBarHeader({required this.morph});

  final PlayerMorphController morph;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: morph,
      builder: (context, _) {
        final showTrack = !morph.barHeaderHidden;
        return Row(
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedOpacity(
                    // 顶栏⇄播放页飞行落位时，真身封面必须与副本移除同帧亮出
                    // （duration 0 = 同步跳变）；收起方向的淡出保持 160ms。
                    duration: showTrack
                        ? Duration.zero
                        : const Duration(milliseconds: 160),
                    opacity: showTrack ? 1 : 0,
                    child: _BarCover(
                      key: morph.barCoverKey,
                      enabled: showTrack,
                    ),
                  ),
                  AnimatedOpacity(
                    duration: showTrack
                        ? Duration.zero
                        : const Duration(milliseconds: 160),
                    opacity: showTrack ? 0 : 1,
                    child: Image.asset(
                      'assets/icons/adaptive_icon_monochrome.png',
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 160),
                    opacity: showTrack ? 1 : 0,
                    child: const _BarTrackInfo(),
                  ),
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 160),
                    opacity: showTrack ? 0 : 1,
                    child: const _AppTitleText(),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 顶栏封面锚点：跟随当前曲目；无封面时音符图标兜底。
///
/// 点击封面切换播放/暂停（与播放页大封面同语义）；仅当顶栏展示曲目封面
/// （[enabled]，播放页激活/飞行中为 false，此时显示 App 图标）且有可播放
/// 曲目（含冷启动恢复态）时生效。
class _BarCover extends StatelessWidget {
  const _BarCover({super.key, required this.enabled});

  /// 顶栏当前是否展示曲目封面（对应 [_ShellBarHeader] 的 showTrack）。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final (coverUrl, hasTrack) =
        context.select<PlaybackProvider, (String?, bool)>(
      (provider) {
        final url = provider.snapshot.current?.artwork?.uri.toString();
        return (
          url == null || url.isEmpty ? null : url,
          provider.hasTrack,
        );
      },
    );
    final image = AppNetworkImage(
      url: coverUrl,
      borderRadius: BorderRadius.circular(8),
      fallbackIconSize: 18,
    );
    return SizedBox(
      width: 32,
      height: 32,
      // 刻意不用 M3ETappable：它点击时会请求焦点，搜索页输入中点击封面
      // 会收起软键盘；GestureDetector 与播放页封面的点击实现保持一致。
      //
      // 用 onTap null 而不是切换子节点结构：避免 enabled 翻转时 AppNetworkImage
      // 重新挂载（重订阅/重放淡入），顶栏⇄播放页共享封面交接时闪一下。
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled && hasTrack
            ? () {
                HapticFeedback.lightImpact();
                context.read<PlaybackProvider>().togglePlayPause();
              }
            : null,
        child: image,
      ),
    );
  }
}

/// 顶栏「下一首」按钮（设置按钮左侧）：无曲目（含冷启动恢复态）时禁用，
/// 避免空操作误导；`select` 只订阅 hasTrack，不触发整个 Shell 重建。
class _BarNextButton extends StatelessWidget {
  const _BarNextButton();

  @override
  Widget build(BuildContext context) {
    final hasTrack = context.select<PlaybackProvider, bool>(
      (provider) => provider.hasTrack,
    );
    final l10n = AppLocalizations.of(context)!;
    return M3EIconButton(
      variant: M3EIconButtonVariant.tonal,
      tooltip: l10n.nextTrackTooltip,
      icon: const Icon(Icons.skip_next_rounded),
      onPressed: hasTrack
          ? () {
              HapticFeedback.lightImpact();
              context.read<PlaybackProvider>().skipToNext();
            }
          : null,
    );
  }
}

/// 顶栏歌名/作者锚点；无曲目时回退到自定义应用名。
class _BarTrackInfo extends StatelessWidget {
  const _BarTrackInfo();

  @override
  Widget build(BuildContext context) {
    final info = context.select<PlaybackProvider, (String?, String?)>(
      (provider) {
        final track = provider.snapshot.current;
        final artists = track?.artists
            .map((artist) => artist.name)
            .where((name) => name.isNotEmpty)
            .join(', ');
        return (track?.title, artists);
      },
    );
    final (name, artists) = info;
    if (name == null || name.isEmpty) {
      return const _AppTitleText();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name,
          style: Theme.of(context).textTheme.titleMedium,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        if (artists != null && artists.isNotEmpty)
          Text(
            artists,
            style: Theme.of(context).textTheme.labelSmall,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
      ],
    );
  }
}

/// 自定义应用名（设置页可改，未自定义时随语言为 Molia/茉咏）。
class _AppTitleText extends StatelessWidget {
  const _AppTitleText();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: AppBrandingService.titleNotifier,
      builder: (context, title, _) => Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 顶栏底部进度条锚点：播放页激活时收起（进度由页面内的同一元素承接）。
class _ShellBarProgress extends StatelessWidget {
  const _ShellBarProgress({required this.morph});

  final PlayerMorphController morph;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: morph,
      builder: (context, _) => AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: morph.barHeaderHidden ? 0 : 1,
        child: ProgressBarSelector(
          builder: (context, position, state, child) {
            if (!state.hasTrack) return const SizedBox(height: 10);
            return ProgressIndicator(
              position: position,
              duration: state.duration.toDouble(),
              // 暂停时顶栏进度也切平直（波浪动画看起来像还在播放）。
              isPlaying: state.isPlaying,
            );
          },
        ),
      ),
    );
  }
}
