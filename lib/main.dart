import 'dart:async';

import 'package:material_ui/material_ui.dart';
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
import 'providers/lyrics_display_provider.dart';
import 'providers/nav_provider.dart';
import 'providers/playback_provider.dart';
import 'providers/search_provider.dart';
import 'providers/discover_provider.dart';
import 'providers/sources_provider.dart';
import 'providers/theme_provider.dart';
import 'services/cache_service.dart';
import 'managers/artwork_cache.dart';
import 'services/data_saver_service.dart';
import 'providers/lyrics_provider.dart';
import 'services/lyrics_display/audio_route_monitor.dart';
import 'services/lyrics_display/desktop_lyrics_output.dart';
import 'services/lyrics_display/lyrics_display_settings.dart';
import 'services/lyrics_display/media_lyric_output.dart';
import 'services/notification_service.dart';
import 'services/settings_service.dart';
import 'sources/source_manager.dart';

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
  final audioHandler = await initSystemMediaSession(
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

  // 歌词会话提前创建：歌词显示调度需要主动取词（不依赖播放页打开），
  // 与播放页共享同一个实例（去重/预取行为不变）。
  final lyricsProvider = LyricsProvider();

  // 歌词显示（桌面歌词 / 通知·锁屏 / 蓝牙）：配置 + 输出 + 调度。
  // 输出端能力由平台决定；媒体输出依赖系统媒体会话（audioHandler）。
  // 主题实例提前创建：桌面歌词「跟随主题」的颜色来自 ThemeProvider
  // （莫奈 / 封面取色统一出口），主题变化时调度会重新下发配置。
  final themeProvider = ThemeProvider();
  final lyricsDisplaySettings = LyricsDisplaySettings();
  await lyricsDisplaySettings.init();
  final audioRouteMonitor = AudioRouteMonitor();
  unawaited(audioRouteMonitor.init());
  final lyricsDisplay = LyricsDisplayProvider(
    settings: lyricsDisplaySettings,
    outputs: [
      DesktopLyricsOutput(colorScheme: () => themeProvider.colorScheme),
      MediaLyricOutput(
        supported: () => audioHandler != null,
        applyOverride: (override) =>
            audioHandler?.setLyricMetadataOverride(override),
        a2dpConnected: () => audioRouteMonitor.connected,
      ),
    ],
    audioRoute: audioRouteMonitor,
    themeListenable: themeProvider,
    ensureLyrics: (track) => lyricsProvider.load(track),
    onPlaybackCommand: (command) {
      switch (command) {
        case LyricsPlaybackCommand.playPause:
          unawaited(playbackProvider.togglePlayPause());
        case LyricsPlaybackCommand.previous:
          unawaited(playbackProvider.skipToPrevious());
        case LyricsPlaybackCommand.next:
          unawaited(playbackProvider.skipToNext());
      }
    },
  );
  // 状态接线：播放快照 / 进度 / 歌词状态 → 调度；冷启动恢复态也走同一路径。
  playbackProvider.addListener(
    () => lyricsDisplay.syncPlayback(playbackProvider.snapshot),
  );
  playbackProvider.position.addListener(
    () => lyricsDisplay.updatePosition(playbackProvider.currentPosition),
  );
  lyricsProvider.addListener(
    () => lyricsDisplay.syncLyrics(lyricsProvider.state),
  );
  lyricsDisplay.syncPlayback(playbackProvider.snapshot);

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
        ChangeNotifierProvider.value(value: themeProvider),
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
        ChangeNotifierProvider.value(value: lyricsProvider),
        // 歌词显示：配置（设置页读写）+ 调度（桌面/通知/蓝牙输出）。
        ChangeNotifierProvider.value(value: lyricsDisplaySettings),
        ChangeNotifierProvider.value(value: lyricsDisplay),
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

