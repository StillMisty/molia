import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

import 'app/app_shell.dart';
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
import 'providers/lyrics_provider.dart';
import 'services/notification_service.dart';
import 'services/settings_service.dart';
import 'sources/source_manager.dart';
import 'theme/animated_scheme.dart';
import 'theme/app_theme.dart';

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
        // 渠道变化 → 搜索源跟随的唯一规则点（页面不再同步两个 provider）。
        ChangeNotifierProvider(
          create: (context) => DiscoverProvider(
            playbackProvider: context.read<PlaybackProvider>(),
            libraryProvider: context.read<LibraryProvider>(),
            onChannelChanged: (key) {
              final search = context.read<SearchProvider>();
              if (search.sourceOptions
                  .any((option) => option.key == key && option.canSearch)) {
                search.selectSource(key);
              }
            },
          ),
        ),
        ChangeNotifierProvider(create: (_) => LyricsProvider()),
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

