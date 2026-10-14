import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import 'app/app_shell.dart';
import 'data/catalog/album_service.dart';
import 'data/catalog/catalog_service.dart';
import 'data/catalog/comments_service.dart';
import 'data/catalog/source_registry_impl.dart';
import 'data/downloads/download_storage.dart';
import 'data/downloads/downloads_publisher.dart';
import 'data/downloads/downloads_repository.dart';
import 'data/library_repository.dart';
import 'data/mapping/track_mapper.dart';
import 'data/play_statistics_repository.dart';
import 'data/sync/adapters/history_sync_adapter.dart';
import 'data/sync/adapters/playlist_sync_adapter.dart';
import 'data/sync/adapters/prefs_sync_adapter.dart';
import 'data/sync/adapters/script_sync_adapter.dart';
import 'data/sync/adapters/session_sync_adapter.dart';
import 'data/sync/adapters/statistics_sync_adapter.dart';
import 'data/sync/sync_crypto.dart';
import 'data/sync/sync_engine.dart';
import 'data/settings/settings_keys.dart';
import 'data/settings/settings_registry.dart';
import 'data/sync/sync_state_store.dart';
import 'data/sync/transport/lan_sync_transport.dart';
import 'data/sync/transport/webdav_sync_transport.dart';
import 'data/update/update_downloader.dart';
import 'data/update/update_manifest_client.dart';
import 'providers/ai_dj_provider.dart';
import 'data/playback/default_playback_facade.dart';
import 'data/playback/local_playback_backend.dart';
import 'domain/models/download.dart';
import 'domain/models/failure.dart';
import 'domain/models/device_sync.dart';
import 'domain/ports/music_source.dart' show PlayableStream;
import 'domain/ports/source_registry.dart';
import 'domain/ports/ui_messenger.dart';
import 'l10n/app_localizations.dart';
import 'playback/audio_predownloader.dart';
import 'playback/desktop_audio_init.dart';
import 'playback/local_audio_handler.dart';
import 'playback/local_playback_service.dart';
import 'playback/next_track_preloader.dart';
import 'providers/comments_provider.dart';
import 'providers/library_provider.dart';
import 'providers/local_database_provider.dart';
import 'providers/lyrics_display_provider.dart';
import 'providers/nav_provider.dart';
import 'providers/playback_provider.dart';
import 'providers/play_statistics_provider.dart';
import 'providers/search_provider.dart';
import 'providers/source_swap_provider.dart';
import 'providers/discover_provider.dart';
import 'providers/sources_provider.dart';
import 'providers/sync_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/update_provider.dart';
import 'services/app_logging.dart';
import 'services/artwork_palette_service.dart';
import 'services/app_branding_service.dart';
import 'services/cache_service.dart';
import 'services/track_cache_service.dart';
import 'managers/artwork_cache.dart';
import 'services/data_saver_service.dart';
import 'services/download/download_service.dart';
import 'services/download/download_settings.dart';
import 'services/language_service.dart';
import 'providers/lyrics_provider.dart';
import 'services/lyrics_display/audio_route_monitor.dart';
import 'services/lyrics_display/desktop_lyrics_output.dart';
import 'services/lyrics_display/lyrics_display_settings.dart';
import 'services/lyrics_display/media_lyric_output.dart';
import 'services/lyrics_service.dart';
import 'services/notification_service.dart';
import 'services/playback_session_store.dart';
import 'services/play_statistics_service.dart';
import 'services/ai/ai_recommendation_service.dart';
import 'services/ai/ai_settings_store.dart';
import 'services/ai/llm_client.dart';
import 'services/ai/taste_profile_builder.dart';
import 'services/source_swap/auto_source_swap_service.dart';
import 'services/source_swap/source_swap_settings.dart';
import 'services/update/update_installer.dart';
import 'services/update/update_preferences.dart';
import 'services/update/update_service.dart';
import 'services/window/window_chrome.dart';
import 'sources/source_manager.dart';

/// composition root 内的 UiMessenger 适配器：唯一持有 navigatorKey /
/// scaffoldMessengerKey 的提示出口，把领域失败映射为 l10n 文案。
///
/// 错误提示统一经此注入；provider 不 import `main.dart`
/// （docs/architecture.md §2.1）。
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
      case 'downloadFileMissing':
        // 本地下载文件缺失：播放取链时归一化出的可读提示。
        return l10n.downloadFileMissing;
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

  // 日志装配（package:logging 的 handler / level 只在这里和测试配置里设一次）
  initAppLogging();

  // 桌面窗口 chrome（Linux/Windows）：隐藏原生标题栏，窗口按钮改由顶栏承担；
  // 其余平台是空操作（Web/移动端走 stub，不触碰插件 API）。
  // 放在 runApp 之前：首帧渲染时标题栏已是隐藏态，不会闪一下系统标题栏。
  await WindowChrome.ensureInitialized();

  // 桌面端本地播放后端（Windows/Linux: media_kit）
  initDesktopAudioIfNeeded();

  // 设置注册表（登记键的唯一家）：读 / 写 / 同步往返 / 应用远端后的 reload
  // 钩子都走它；键的声明见 data/settings/settings_keys.dart。
  final settingsRegistry = SettingsRegistry(keys: kAllSettingsKeys);
  // 全静态服务（语言 / 品牌名）：attach 注入注册表，reload 由组合根代绑。
  LanguageService.attachSettings(settingsRegistry);
  AppBrandingService.attachSettings(settingsRegistry);
  settingsRegistry.bindReload(
      kSelectedLanguage, LanguageService.reloadFromPreferences);
  settingsRegistry.bindReload(kAppDisplayTitle, AppBrandingService.load);

  final sourceManager = SourceManager(settings: settingsRegistry);

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
  // 评论：与目录服务同构的缓存层（single-flight + LRU + 5min TTL，
  // key = comments:{source}:{songId}:{kind}:{page}）。
  final commentsService = CommentsService(registry: sourceRegistry);
  // 专辑：同一取数模式（single-flight + LRU + 10min TTL，
  // key = album:{source}:{albumId}:{page}）；取数注入 SourceManager.fetchAlbum，
  // 服务本身不依赖 sources 层。
  final albumService = AlbumService(
    fetch: (sourceKey, albumId, {required page, required limit}) =>
        sourceManager.fetchAlbum(sourceKey, albumId,
            page: page, limit: limit),
  );

  // 下载设置（设备本地：保存位置 / 文件名格式 / 标签嵌入开关）。
  final downloadSettings = DownloadSettings();
  await downloadSettings.init();

  // 本地下载：持久副本 + 离线歌词/封面 + 音频标签嵌入。
  // 存储不可用（Web）时 supported=false，UI 隐藏下载入口；初始化失败不阻断
  // 启动（init 内部已吞错）。下载时的取词/取图**缓存优先**：歌词与播放页
  // 共用同一个 LyricsService（缓存 → 原生 → 跨平台回退），封面经 ArtworkCache
  // 命中直读、未命中取图后回填；音频命中完整缓存时直接拷贝，不触网。
  late final LyricsService lyricsService;
  final downloadService = DownloadService(
    catalog: catalogService,
    repository: DownloadsRepository(),
    storage: createDownloadStorage(
      customRoot: () => downloadSettings.saveDir,
    ),
    cacheService: CacheService.instance,
    artworkCache: ArtworkCache.instance,
    settings: downloadSettings,
    publisher: createDownloadsPublisher(),
    lyricsResolver: (track) async {
      final result = await lyricsService.getLyrics(
        track.title,
        track.artists
            .map((artist) => artist.name)
            .where((name) => name.isNotEmpty)
            .join(', '),
        track.id.uri,
        track: track,
      );
      if (result == null || result.lyric.trim().isEmpty) return null;
      return DownloadLyrics(
        lyric: result.lyric,
        translation: result.translation,
      );
    },
    artworkResolver: (track) =>
        sourceManager.fetchPic(sourceTrackFromTrack(track)),
    preferredQuality: () =>
        dataSaver.effectiveQuality(sourceManager.preferredQuality),
  );
  await downloadService.init();

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
    // 下一首预载：起播后预热直链（命中取链缓存）+ 音频字节预取到缓存；
    // 省流实际生效（移动数据 + 已开启）时只预热直链，不预下载。
    nextTrackPreloader: NextTrackPreloader(
      resolver: (track, {String? quality}) =>
          playbackBackend.resolveLegacyUrl(track, quality: quality),
      preferredQuality: () =>
          dataSaver.effectiveQuality(sourceManager.preferredQuality),
      predownloader: CacheAudioPredownloader(
        cacheService: CacheService.instance,
        allowed: () => !dataSaver.active,
      ),
    ),
  );
  playbackBackend = LocalPlaybackBackend(
    service: localPlayback,
    // 取链外层装饰：优先命中本地下载副本（文件存在时直接 file://），
    // 未命中回落既有 CatalogService（single-flight + LRU + TTL 不变）。
    resolver: (track, quality) async {
      final local = await downloadService.localUriFor(track);
      if (local != null) return PlayableStream(local);
      return catalogService.resolve(track, quality: quality);
    },
  );
  final playbackFacade = DefaultPlaybackFacade(backend: playbackBackend);

  // 本地播放服务在 main 中创建：系统媒体会话（audio_service）需在 runApp
  // 之前初始化，并复用同一个 LocalPlaybackService 实例。
  // 不支持 audio_service 的平台（Linux/Windows/Web）返回 null，自动降级。
  // 省流时通知/锁屏封面置空，避免 audio_service 为通知下载封面。
  // 恢复态（冷启动未起播）切歌键回落给 PlaybackProvider：handler 先于
  // provider 创建，这里用可变槽位在下方创建后接线。
  PlaybackProvider? restoredControlsTarget;
  final audioHandler = await initSystemMediaSession(
    localPlayback,
    artworkBlocked: () => dataSaver.blockNetworkArtwork,
    onRestoredSkipToNext: () async {
      await restoredControlsTarget?.skipToNext();
    },
    onRestoredSkipToPrevious: () async {
      await restoredControlsTarget?.skipToPrevious();
    },
  );

  // 唯一 composition root：PlaybackProvider 的报错出口（UiMessenger）与
  // 写库/预加载所需 Context 全部在此注入。
  // NotificationService 提前创建：UiMessenger 与 Provider 共用同一实例。
  final notificationService = NotificationService(
    scaffoldMessengerKey,
    hostContextKey: appRootKey,
  );
  // 资料库仓库：播放历史 / 我的列表 / 收藏；播放开始时由
  // PlaybackProvider 写历史，资料库页经 LibraryProvider 读取（内存缓存）。
  // 跨设备同步状态提前初始化：资料库/统计的写路径需要设备 id 打同步戳。
  final syncState = SyncStateStore();
  await syncState.init();
  final libraryRepository = LibraryRepository(
    deviceIdProvider: () => syncState.deviceId,
  );
  // 听歌统计：事件级采集（play_events）与查询；与「最近播放」（play_history，
  // 500 条上限）是两套数据。采集是纯观察者（服务不持有 provider），
  // 快照 / 进度经下方 addListener 接线；上次进程被杀遗留的进行中事件
  // 启动即收尾为 interrupted。
  final playStatisticsRepository = PlayStatisticsRepository(
    deviceIdProvider: () => syncState.deviceId,
  );
  final playStatisticsService = PlayStatisticsService(
    repository: playStatisticsRepository,
    settings: settingsRegistry,
  );
  await playStatisticsService.init();
  unawaited(playStatisticsRepository.closeStaleEvents());
  // 最近播放上下文（play_contexts）：提前创建，同一实例既进 Provider 树，
  // 也直接注入 PlaybackProvider。
  final localDatabaseProvider = LocalDatabaseProvider();
  // 换源偏好（自动换源开关，默认开）与自动换源解析服务：
  // 播放失败同源重试仍失败时，经注入的 resolver 跨音源严格找回并替换。
  final sourceSwapSettings = SourceSwapSettings(settings: settingsRegistry);
  await sourceSwapSettings.init();
  final autoSourceSwapService = AutoSourceSwapService(
    catalog: catalogService,
    registry: sourceRegistry,
  );
  final playbackProvider = PlaybackProvider(
    settings: settingsRegistry,
    facade: playbackFacade,
    messenger: _AppUiMessenger(notificationService),
    sourceManager: sourceManager,
    navigatorKey: navigatorKey,
    catalogService: catalogService,
    libraryRepository: libraryRepository,
    dataSaver: dataSaver,
    localDatabaseProvider: localDatabaseProvider,
    autoSwapSettings: sourceSwapSettings,
    autoSwapResolver: (track, {required excludeSourceKeys}) =>
        autoSourceSwapService.findMatch(
      track,
      excludeSourceKeys: excludeSourceKeys,
    ),
    // 封面补取：曲目起播无封面时经 SourceManager 现取（脚本 pic →
    // 内置平台原生取图），省流模式不发请求；取到后原地回写队列曲目。
    artworkResolver: (track) async {
      if (dataSaver.blockNetworkArtwork) return null;
      return sourceManager.fetchPic(sourceTrackFromTrack(track));
    },
  );
  // 系统媒体会话的恢复态切歌键（耳机/媒体键）落到 provider：用保存的
  // 会话立即恢复播放（handler 创建时 provider 尚不存在，见上方注释）。
  restoredControlsTarget = playbackProvider;

  // 资料库（收藏/历史/列表）：AI 推歌把「收藏」当喜欢反馈，需要提前创建
  // 并直接进 Provider 树。
  final libraryProvider = LibraryProvider(
    repository: libraryRepository,
    playbackProvider: playbackProvider,
  );

  // AI 推歌：配置（安全存储）+ OpenAI-compatible 客户端 +
  // 画像/生成服务 + 模式控制器。组合根把播放快照 / 进度接进控制器
  //（跳过判定与低水位续推都在控制器里）。
  final aiSettingsStore = AiSettingsStore(settings: settingsRegistry);
  final aiRecommendationService = AiRecommendationService(
    llm: LlmClient(),
    catalog: catalogService,
    registry: sourceRegistry,
    profileBuilder: TasteProfileBuilder(repository: playStatisticsRepository),
  );
  final aiDjProvider = AiDjProvider(
    playbackProvider: playbackProvider,
    libraryProvider: libraryProvider,
    recommendationService: aiRecommendationService,
    settingsStore: aiSettingsStore,
  );
  unawaited(aiDjProvider.init());
  playbackProvider.addListener(aiDjProvider.onPlaybackChanged);
  playbackProvider.position.addListener(aiDjProvider.onPositionChanged);

  // 歌词会话提前创建：歌词显示调度需要主动取词（不依赖播放页打开），
  // 与播放页共享同一个实例（去重/预取行为不变）。
  // 曲目原生取词经 SourceManager 统一路由：脚本 lyric action →
  // any-listen → 内置平台原生实现（wy/tx/kg/kw/mg，精确平台 ID）。
  final lyricsProvider = LyricsProvider(
    service: lyricsService = LyricsService(
      // 本地下载曲目：离线歌词缺失时不回退网络（离线播放全程不触网）。
      networkFallbackAllowed: (track) =>
          track.id.sourceKey != kLocalSourceKey,
      trackLyricLoader: (track) async {
        // 本地下载曲目：读 downloads/lyrics/ 的离线歌词（不触网）；
        // 无离线歌词返回 null，交给既有歌词源（在线时仍可补全）。
        if (track.id.sourceKey == kLocalSourceKey) {
          return downloadService.localLyricsFor(track);
        }
        final result =
            await sourceManager.fetchLyric(sourceTrackFromTrack(track));
        if (result == null || result.lyric.trim().isEmpty) return null;
        return LyricsResult(
          lyric: result.lyric,
          translation: result.tlyric,
          roma: result.rlyric,
          lxlyric: result.lxlyric,
          provider: track.id.sourceKey,
        );
      },
    ),
  );

  // 歌词显示（桌面歌词 / 通知·锁屏 / 蓝牙）：配置 + 输出 + 调度。
  // 输出端能力由平台决定；媒体输出依赖系统媒体会话（audioHandler）。
  // 主题实例提前创建：封面覆盖 / 桌面歌词「跟随主题」「跟随封面」的颜色
  // 都从 ThemeProvider 取（取色链路在下方接线）。
  final themeProvider = ThemeProvider(settings: settingsRegistry);
  // 导航偏好提前创建：跨设备同步应用远端设置后需要定向重载。
  final navProvider = NavProvider(settings: settingsRegistry);
  // 封面取色服务：全局主题、桌面歌词、海报共用的唯一取色入口。
  final artworkPaletteService = ArtworkPaletteService();
  final artworkThemeSync = ArtworkThemeSync(
    load: artworkPaletteService.load,
    onPalette: (palette) => themeProvider.applyArtworkSeed(palette.seed),
    onCleared: themeProvider.clearArtworkSeed,
  );
  final lyricsDisplaySettings =
      LyricsDisplaySettings(settings: settingsRegistry);
  await lyricsDisplaySettings.init();
  final audioRouteMonitor = AudioRouteMonitor();
  unawaited(audioRouteMonitor.init());
  final lyricsDisplay = LyricsDisplayProvider(
    settings: lyricsDisplaySettings,
    outputs: [
      DesktopLyricsOutput(
        colorScheme: () => themeProvider.colorScheme,
        artworkColorScheme: () => themeProvider.artworkColorScheme,
      ),
      MediaLyricOutput(
        supported: () => audioHandler != null,
        applyOverride: (override) =>
            audioHandler?.setLyricMetadataOverride(override),
        a2dpConnected: () => audioRouteMonitor.connected,
      ),
    ],
    // 平台支持媒体会话但初始化失败（audio_service init 返回 null）：
    // 歌词显示设置页据此给出可见提示，而不是静默隐藏输出分组。
    mediaSessionInitFailed:
        isSystemMediaSessionSupported && audioHandler == null,
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

  // 下一首歌词预载：统一挂在这里，不依赖歌词组件是否挂载/展开；
  // 去重与缓存写入由 LyricsProvider.preload 负责。
  String? preloadedNextLyricsId;
  void syncNextTrackLyricsPreload() {
    final snapshot = playbackProvider.snapshot;
    final next = snapshot.next ??
        (snapshot.upNext.isNotEmpty ? snapshot.upNext.first : null);
    final id = next?.id.uri;
    if (next == null ||
        id == null ||
        id.isEmpty ||
        id == preloadedNextLyricsId) {
      return;
    }
    preloadedNextLyricsId = id;
    unawaited(lyricsProvider.preload(next));
  }

  playbackProvider.addListener(syncNextTrackLyricsPreload);
  syncNextTrackLyricsPreload();

  // 封面取色接线：任何页面/后台切歌都经同一链路（稳态延迟 + 过期丢弃）。
  // 无封面 → 清空 seed，主题回退基础配色；取色失败保持现色。
  void syncArtworkPalette() {
    final artwork = playbackProvider.snapshot.current?.artwork?.uri.toString();
    artworkThemeSync.onArtworkChanged(artwork);
  }

  playbackProvider.addListener(syncArtworkPalette);
  syncArtworkPalette();

  // 听歌统计接线：曲目/播放态快照 + 进度 tick → 采集服务（纯观察者，零改动
  // 播放内核）。与歌词显示同一模式：composition root 只做两根监听。
  playbackProvider.addListener(
    () => playStatisticsService.onSnapshot(playbackProvider.snapshot),
  );
  playbackProvider.position.addListener(
    () => playStatisticsService.onPosition(playbackProvider.currentPosition),
  );
  playStatisticsService.onSnapshot(playbackProvider.snapshot);

  // 跨设备数据同步（ADR-0003）：口令即信任根，加入同步的设备完全互信
  // （含音源脚本与凭证），因此不逐项审批；Web 端不提供入口。
  final syncCodec = SyncCodec();
  // 脚本同步的保留键：音源类别的设置键（避免脚本墓碑与设置键同名冲突）。
  final sourceCategoryKeys = {
    for (final key in settingsRegistry.keys)
      if (key.category == SyncCategory.sources) key.name,
  };
  final playlistSyncAdapter =
      PlaylistSyncAdapter(repository: libraryRepository);
  final scriptSyncAdapter = ScriptSyncAdapter(
    repository: sourceManager.repository,
    state: syncState,
    deviceId: () => syncState.deviceId,
    now: () => DateTime.now().millisecondsSinceEpoch,
    ready: () => sourceManager.initialized,
    reservedKeys: sourceCategoryKeys,
    onScriptsChanged: sourceManager.refreshScriptsFromStorage,
  );
  final prefsSyncAdapter = PrefsSyncAdapter(
    state: syncState,
    settings: settingsRegistry,
    deviceId: () => syncState.deviceId,
    now: () => DateTime.now().millisecondsSinceEpoch,
    // 应用远端设置后：注册表按键触发模块自绑的重载钩子（不再手写清单）。
    onApplied: settingsRegistry.reloadKeys,
  );
  final statisticsSyncAdapter =
      StatisticsSyncAdapter(repository: playStatisticsRepository);
  final historySyncAdapter =
      HistorySyncAdapter(repository: libraryRepository);
  final sessionSyncAdapter = SessionSyncAdapter(
    store: PlaybackSessionStore(),
    state: syncState,
    deviceId: () => syncState.deviceId,
    onChanged: playbackProvider.reloadRestoredSessionFromStore,
  );

  late final SyncEngine syncEngine;
  final lanSyncTransport = LanSyncTransport(
    deviceId: syncState.deviceId,
    deviceName: () => syncState.deviceName,
    codec: syncCodec,
    passphraseProvider: syncState.readPassphrase,
    snapshotProvider: () async =>
        syncEngine.lastEnvelope ??
        SyncEnvelope(
          deviceId: syncState.deviceId,
          deviceName: syncState.deviceName,
          producedAt: DateTime.now().millisecondsSinceEpoch,
        ),
  );
  final webdavSyncTransport = WebDavSyncTransport(
    deviceId: syncState.deviceId,
    codec: syncCodec,
    passphraseProvider: syncState.readPassphrase,
    configProvider: () => syncState.webdav,
    passwordProvider: syncState.readWebdavPassword,
  );
  syncEngine = SyncEngine(
    state: syncState,
    adapters: [
      playlistSyncAdapter,
      historySyncAdapter,
      scriptSyncAdapter,
      prefsSyncAdapter,
      statisticsSyncAdapter,
      sessionSyncAdapter,
    ],
    transports: {'lan': lanSyncTransport, 'webdav': webdavSyncTransport},
  );
  final syncProvider = SyncProvider(engine: syncEngine);
  // 可选子系统（跨设备同步）初始化失败不允许阻断启动：runApp 之前任何
  // 未捕获异常都会让桌面端停在「窗口已显示但没有首帧」的黑窗状态。
  // 口令读取失败已在 SecureSettingsSecretStore 内降级为「未设置」，
  // 这里再兜一层其它初始化异常（日志 + 继续，同步页表现为未配置）。
  try {
    await syncProvider.init();
  } catch (e) {
    debugPrint('[Molia] 同步初始化失败（继续启动）: $e');
  }
  // 数据变更 → 去抖同步（资料库 / 统计 / 音源配置）；前台恢复补一轮；
  // 运行期间每 10 分钟一轮（局域网对端在线时也能收敛）。
  libraryRepository.changes.listen((_) => syncProvider.scheduleSync());
  playStatisticsRepository.changes.listen((_) => syncProvider.scheduleSync());
  sourceManager.addListener(syncProvider.scheduleSync);
  Timer.periodic(const Duration(minutes: 10), (_) {
    if (syncProvider.enabled) unawaited(syncProvider.syncNow());
  });

  // 应用内更新：清单（Release 资产 latest.json）→ 下载（sha256 强制校验）
  // → 平台安装策略（Android 系统安装器 / 桌面替换脚本 / Web 刷新）。
  // 版本号来自平台包信息，CI 用 --build-name/--build-number 注入（见
  // docs/release.md）；读不到时退化为 0.0.0（仍可检查，只是比较无基准）。
  String appVersion = '0.0.0';
  int appBuild = 0;
  try {
    final packageInfo = await PackageInfo.fromPlatform();
    appVersion = packageInfo.version;
    appBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
  } catch (e) {
    debugPrint('[Molia] 读取应用版本失败（更新检查按 0.0.0 处理）: $e');
  }
  final updatePreferences = UpdatePreferences();
  final updateProvider = UpdateProvider(
    service: UpdateService(
      client: UpdateManifestClient(
        manifestUrlOverride: () => updatePreferences.manifestUrlOverride,
        downloadPrefix: () => updatePreferences.downloadPrefix,
      ),
      downloader: UpdateDownloader(),
      installer: UpdateInstaller(),
    ),
    preferences: updatePreferences,
    currentVersion: appVersion,
    currentBuild: appBuild,
    // 桌面端替换脚本就绪后由 provider 触发退出，脚本完成替换并重启。
    quitApp: WindowChrome.close,
  );
  await updateProvider.init();

  // 前台恢复：补一轮同步；并复查更新安装权限——从「安装未知应用」系统
  // 授权页返回后要把按钮从「去授权」切回「立即安装」。
  AppLifecycleListener(
    onResume: () {
      syncProvider.scheduleSync(delay: const Duration(seconds: 3));
      unawaited(updateProvider.handleAppResumed());
    },
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
        // 专辑页取数（缓存/错误边界在服务内；页面只消费领域 Album）。
        Provider<AlbumService>.value(value: albumService),
        // 评论页状态：热门 / 最新分页 + 刷新（评论缓存走 CommentsService）。
        ChangeNotifierProvider(
          create: (_) => CommentsProvider(
            service: commentsService,
            registry: sourceRegistry,
          ),
        ),
        ChangeNotifierProvider.value(value: playbackProvider),
        ChangeNotifierProvider.value(value: themeProvider),
        // 封面取色服务（海报「跟随封面」按需查询；主题链路已在上方接线）。
        Provider<ArtworkPaletteService>.value(value: artworkPaletteService),
        ChangeNotifierProvider.value(value: navProvider),
        ChangeNotifierProvider(
          create: (context) => SearchProvider(
            context.read<PlaybackProvider>(),
            catalogService: catalogService,
            sourceRegistry: sourceRegistry,
          ),
        ),
        ChangeNotifierProvider.value(value: localDatabaseProvider),
        // 资料库（收藏/历史/列表）：顶层创建（AI 推歌读取收藏作为反馈）。
        ChangeNotifierProvider.value(value: libraryProvider),
        // 换源：跨音源搜索 + 原位替换 + 队列跟随（收藏页 / 播放页入口）。
        ChangeNotifierProvider(
          create: (context) => SourceSwapProvider(
            catalogService: catalogService,
            sourceRegistry: sourceRegistry,
            libraryProvider: context.read<LibraryProvider>(),
            playbackProvider: context.read<PlaybackProvider>(),
          ),
        ),
        // AI 推歌：模式控制器 + 配置存储 + 生成服务。
        ChangeNotifierProvider.value(value: aiDjProvider),
        Provider<AiSettingsStore>.value(value: aiSettingsStore),
        Provider<AiRecommendationService>.value(value: aiRecommendationService),
        // 听歌统计：仓库（查询）与采集服务（开关）；统计页读取这两个实例。
        Provider<PlayStatisticsRepository>.value(
            value: playStatisticsRepository),
        Provider<PlayStatisticsService>.value(value: playStatisticsService),
        // 听歌统计页状态（范围 / 加载 / 清空 / 导出）；页面打开期间
        // 自行订阅仓库变更，关闭后取消。
        ChangeNotifierProvider(
          create: (_) => PlayStatisticsProvider(
            repository: playStatisticsRepository,
          ),
        ),
        // 发现页：热榜 / 歌单 / 热搜；播放与收藏复用上面两个 provider。
        // 渠道变化 → 搜索源跟随的唯一规则点（页面不自行同步两个 provider）。
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
        // 单曲缓存门面（音频/歌词/封面/取链）：播放页「歌曲信息」页消费。
        Provider<TrackCacheService>(
          create: (_) => TrackCacheService(
            cacheService: CacheService.instance,
            artworkCache: ArtworkCache.instance,
            catalogService: catalogService,
          ),
        ),
        // 本地下载：歌曲信息页「下载」行与「已下载」列表共用同一状态源。
        // 与缓存门面是两套东西：清缓存不触碰 downloads/，删下载是独立动作。
        ChangeNotifierProvider.value(value: downloadService),
        // 下载设置：保存位置 / 文件名格式 / 标签嵌入（设置页读写）。
        ChangeNotifierProvider.value(value: downloadSettings),
        Provider<NotificationService>.value(value: notificationService),
        // 省流模式：设置页读写开关/音质上限；取链与封面网关已在上方接线。
        ChangeNotifierProvider.value(value: dataSaver),
        // 跨设备数据同步：设置页读写；Web 不展示入口。
        ChangeNotifierProvider.value(value: syncProvider),
        // 换源偏好（自动换源开关）：设置页读写；播放链路已在上方接线。
        ChangeNotifierProvider.value(value: sourceSwapSettings),
        // 应用内更新：设置页读写（渠道 / 自动检查 / 下载安装）。
        ChangeNotifierProvider.value(value: updateProvider),
      ],
      child: const MyThemedApp(),
    ),
  );

  // 启动后初始化音源（加载已导入的 LX 音源脚本）；随后发起首轮同步
  // （音源仓库就绪后脚本适配器才能工作）。更新检查默认关闭（用户开启后
  // 每天最多一轮），网络失败静默不打扰。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(updateProvider.maybeAutoCheck());
    sourceManager.init().then((_) {
      if (syncProvider.enabled) unawaited(syncProvider.syncNow());
    });
  });
}

