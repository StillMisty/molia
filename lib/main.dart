import 'dart:async';
import 'dart:io' show exit;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app/app_lifecycle_coordinator.dart';
import 'app/app_shell.dart';
import 'app/bootstrap/ai_stack.dart';
import 'app/bootstrap/app_ui_messenger.dart';
import 'app/bootstrap/catalog_stack.dart';
import 'app/bootstrap/diagnostics_stack.dart';
import 'app/bootstrap/desktop_stack.dart';
import 'app/bootstrap/library_stack.dart';
import 'app/bootstrap/local_data_stack.dart';
import 'app/bootstrap/lyrics_display_stack.dart';
import 'app/bootstrap/lyrics_stack.dart';
import 'app/bootstrap/playback_stack.dart';
import 'app/bootstrap/post_frame_init.dart';
import 'app/bootstrap/provider_tree.dart';
import 'app/bootstrap/startup_trace.dart';
import 'app/bootstrap/sync_stack.dart';
import 'app/bootstrap/update_stack.dart';
import 'app/perf/data_path_scenario.dart';
import 'app/perf/frame_stats.dart';
import 'data/diagnostics/database_counts.dart';
import 'data/diagnostics/settings_snapshot.dart';
import 'data/diagnostics/source_health_probe.dart';
import 'data/diagnostics/source_snapshot.dart';
import 'data/molia_database.dart';
import 'data/settings/settings_keys.dart';
import 'data/settings/settings_module.dart';
import 'managers/app_memory_manager.dart';
import 'playback/desktop_audio_init.dart';
import 'playback/local_audio_handler.dart';
import 'playback/playback_power_policy.dart';
import 'providers/channel_selection.dart';
import 'providers/library_provider.dart';
import 'providers/search_provider.dart';
import 'providers/sync_ui_state.dart';
import 'sources/builtin/builtin_search.dart';
import 'sources/builtin/discover_source.dart';
import 'services/app_logging.dart';
import 'services/diagnostics/app_info.dart';
import 'services/diagnostics/diagnostics_export.dart';
import 'services/diagnostics/source_health_checker.dart';
import 'services/app_presence.dart';
import 'services/global_hotkeys.dart';
import 'services/notification_service.dart';
import 'services/search_history_store.dart';
import 'services/shortcut_actions.dart';
import 'services/system_fonts_service.dart';
import 'services/window/single_instance.dart';
import 'services/window/window_chrome.dart';
import 'services/window/window_settings.dart';

/// 启动耗时埋点（见 `main()` 顶部）：单行日志，release 也输出，
/// 便于「启动迟缓」回归时一眼定位阶段。
final _startupLog = Logger('molia.startup');

void _markStartup(String stage, Stopwatch watch) =>
    _startupLog.info('$stage：${watch.elapsedMilliseconds}ms');

/// 同步状态的诊断投影：只挑布尔 / 计数 / 主机名，口令与密码值不进入快照。
DiagnosticsSyncInfo _diagnosticsSyncInfo(SyncUiState state) {
  String? host(String raw) {
    final uri = Uri.tryParse(raw.trim());
    final value = uri?.host ?? '';
    return value.isEmpty ? null : value;
  }

  return DiagnosticsSyncInfo(
    enabled: state.enabled,
    categories: {
      for (final entry in state.categories.entries) entry.key.name: entry.value,
    },
    transports: [
      for (final transport in state.enabledTransports) transport.name,
    ],
    pairedDevices: state.peers.length,
    webdavConfigured: state.webdav.isConfigured,
    webdavHost: host(state.webdav.baseUrl),
  );
}

/// 系统低内存信号：只有在这种情况下释放可重建的浏览 / 搜索 / 目录缓存。
///
/// 普通退后台不释放列表——恢复时用户会看到空列表并被迫重读；系统明确报告
/// 内存压力时才值得用「恢复后重读」换一次释放。
class _MemoryPressureObserver with WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() => AppMemoryManager.instance.onMemoryPressure();
}

/// 唯一 composition root：只做「平台装配 + 按顺序调用各 stack builder +
/// runApp + 首帧回调」，子系统内部接线见 `lib/app/bootstrap/**`。
///
/// 各 stack builder 内不引入 `late` / 可变槽位 / 前向引用：
/// - 服务 ↔ 后端互为依赖 → 取链是共享解析函数（`local_playback_chain.dart`）；
/// - 歌词服务 ↔ 下载服务互为依赖 → 歌词服务先建、离线歌词读取收在存储级
///   函数里（`local_data_stack.dart`）；
/// - 系统媒体会话 ↔ provider → handler 在 provider 就绪后装配
///   （`playback_stack.dart` 的 `mediaSessionFactory`）；
/// - SyncEngine ↔ 局域网传输 → 快照提供者在同一个 builder 内接线
///   （`sync_stack.dart`）。
///
/// 启动顺序（`unawaited` 的启动维护、各模块 `init()` 的 await、runApp 前的
/// 启动预解析、首帧回调）即下方步骤的调用顺序；系统媒体会话在 provider
/// 建好之后装配（恢复态切歌键要直接落到 provider，见
/// `playback_stack.dart`），仍在 runApp 之前。
void main() async {
  // 启动耗时埋点：每个阶段一行 `molia.startup` 日志（release 也输出），
  // 用来盯住「启动迟缓」回归（首帧那行是用户能感知的总时长）。
  final startup = Stopwatch()..start();

  WidgetsFlutterBinding.ensureInitialized();

  // 图片缓存预算：显式收敛到 64 MiB（Flutter 默认 100 MiB 对移动端过大；
  // 桌面托盘 / 移动端后台还会临时压到 16 MiB）。必须在
  // `AppMemoryManager.instance` 首次访问之前设置：守卫构造时捕获这个值
  // 作为恢复上限。所有平台统一口径，避免各平台恢复出不同预算。
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      kFullImageCacheLimitBytes;

  // 日志装配（package:logging 的 handler / level 只在这里和测试配置里设一次）
  initAppLogging();
  // 诊断核心（失败缓冲 + 轮转文件日志）：构造无 I/O；文件 sink 在首次写入时
  // 才解析应用数据目录，启动不等待磁盘。
  final diagnostics = buildDiagnosticsStack();

  // 帧统计：默认编译期关闭；`MOLIA_PERF_TRACE=true` 时才注册回调。
  FrameStats.instance.install();

  // 托盘期内存守卫：窗口隐藏 / 最小化 / 恢复时清理或恢复图片缓存预算
  // （`molia.memory` 日志是托盘内存回归的观测点）。
  AppMemoryManager.instance.attach();
  // 系统低内存：只释放可重建的浏览 / 搜索 / 目录缓存（见 onMemoryPressure）。
  WidgetsBinding.instance.addObserver(_MemoryPressureObserver());

  // 窗口行为偏好（设备本地）/ 系统 UI 字体 / 单实例锁互不依赖：并行等待
  // （串行是几段相加，并行取最大值）。都完成才建窗，语义与拆分前一致。
  //
  // - 窗口几何的恢复/保存在建窗之前就要判定，因此必须 await；
  // - 系统字体在首帧前解析好，避免先用引擎默认字体画一帧再跳变；Windows
  //   读一次注册表（毫秒级），其它平台是空操作；
  // - 单实例（桌面）：已有实例在跑 → 请它显示主窗口后立即退出；此刻窗口还没
  //   创建，不会闪一下再消失。其余平台 / 抢锁异常按主实例继续。
  final windowSettingsWatch = Stopwatch()..start();
  final windowSettingsFuture =
      defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS
      // 窗口几何只属于桌面；Android/iOS 不读这个设备键，别让首帧
      // 等一次用不到的 prefs 读取。
      ? WindowSettings.load()
      : Future<void>.value();
  final windowPrefixWatch = Stopwatch()..start();
  final (_, _, instanceRole) = await (
    windowSettingsFuture,
    SystemFontsService.loadPlatformDefaultFamily(),
    SingleInstance.acquire(),
  ).wait;
  markStartupStep('sub.windowSettings.load', windowSettingsWatch);
  markStartupStep('sub.window.prefix', windowPrefixWatch);
  if (instanceRole == SingleInstanceRole.secondary) {
    exit(0);
  }

  // 桌面窗口 chrome（Linux/Windows/macOS）：隐藏原生标题栏（macOS 保留原生
  // 标题栏）并恢复几何。Linux/Windows 先建不显、首帧回调里再亮出来（其余平台
  // 是空操作）；macOS 的窗口随 NIB 显示（隐藏窗口会停帧，首帧回调里再 show
  // 起来），那里 `show()` 只是幂等重复。
  final chromeWatch = Stopwatch()..start();
  await WindowChrome.ensureInitialized();
  markStartupStep('sub.windowChrome.init', chromeWatch);
  // 显示兜底：首帧回调是主路径；装配异常 / 卡住时窗口也必须出现（show 幂等）。
  final revealFallback = Timer(
    const Duration(seconds: 5),
    () => unawaited(WindowChrome.show()),
  );
  _markStartup('窗口就绪', startup);

  // 桌面端本地播放后端（Windows/Linux: media_kit）
  initDesktopAudioIfNeeded();

  // 移动端播放功耗策略：与 `AppPresence` 完全独立（后者是桌面窗口可见性，
  // 驱动预取 / 取色停产，移动端退后台不能写进去）。桌面不接生命周期事件，
  // 默认一直前台；启动时若系统已把应用放到后台（如从通知恢复的冷启动），
  // 先按后台节拍采样 / 落盘 / 停后台工作，首帧后再由生命周期回调纠正。
  final powerPolicy = PlaybackPowerPolicy();
  final mobilePowerPolicy =
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  if (mobilePowerPolicy) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden) {
      powerPolicy.markBackground();
    }
  }

  // 提示出口（纯构造，无插件、无 await）：播放 provider 的 UiMessenger
  // 与 Provider 树共用同一实例。
  final notifications = NotificationService(hostContextKey: appRootKey);

  // ① 音源与目录（设置注册表 → SourceManager → 目录/评论/专辑/歌手）。
  final catalog = buildCatalogStack(failures: diagnostics.failures);
  // 主库预热：播放会话首帧前就要读（恢复态可见），提前与本地数据 / 资料库
  // 并行开库。Windows 首次启动的旧库复制 + v1→v2 迁移是一次性成本，单独埋点。
  final dbPrewarmWatch = Stopwatch()..start();
  final databasePrewarm = () async {
    try {
      await MoliaDatabase.instance.customSelect('SELECT 1').get();
    } catch (e) {
      _startupLog.warning('主库预热失败（首个查询会重试）：$e');
    } finally {
      markStartupStep('sub.db.prewarm', dbPrewarmWatch);
    }
  }();
  // ② 本地数据（省流 + 封面网关 + 下载链路 + 歌词服务 + 缓存写入器）
  //    与 ③ 资料库 / 统计 / 换源偏好互不依赖：并行装配，等待取最大值
  //    （串行等待是两段相加，实测该段是启动装配里最大的一块）。
  final (local, library) = await (
    buildLocalDataStack(catalog: catalog),
    // 全库最大戳要打开 drift 库；留给首帧后的 startLibraryAfterFirstFrame
    // （写入方经 stampSeedReady 等种子，不会提前取号）。
    buildLibraryStack(catalog: catalog, deferStampSeed: true),
  ).wait;
  await databasePrewarm;
  _markStartup('本地数据/资料库栈', startup);
  // 健康检查探针依赖目录服务与省流上限：两者都就绪后挂到同一个诊断服务上。
  // 偏好音质直接读正常播放同源的 `dataSaver × sourceManager`，不另建配置。
  diagnostics.service.attachHealth(
    SourceHealthChecker(
      probe: CatalogSourceHealthProbe(
        registry: catalog.sourceRegistry,
        preferredQuality: () => local.dataSaver.effectiveQuality(
          catalog.sourceManager.preferredQuality,
        ),
      ),
    ),
  );
  // ④ 播放链路 + provider + 观察者 + 系统媒体会话。
  final playback = await buildPlaybackStack(
    catalog: catalog,
    local: local,
    library: library,
    messenger: AppUiMessenger(notifications),
    powerPolicy: powerPolicy,
    failures: diagnostics.failures,
    mediaSessionFactory: (service, session) => initSystemMediaSession(
      service,
      // handler 只翻译动作；恢复态回落、阶段路由与提交都在会话命令面。
      commands: session,
      artworkBlocked: () => local.dataSaver.blockNetworkArtwork,
      // 自定义 → 原始 → 默认封面；本地文件由 handler 按平台转裸路径 / URI。
      coverResolver: local.customCovers.resolution,
    ),
  );
  // 标题编辑直接写会话 JSON：先等会话层排空，避免被在途保存写回旧标题。
  local.localMetadata.awaitSessionWrites = () =>
      playback.sessionStore.pendingWrite;
  // 提交后刷新 live 队列 / 恢复态显示（只换元数据，不重新取链）。
  local.localMetadata.onCommitted = (record) {
    final track = record.localTrack;
    if (track == null) return;
    unawaited(playback.playbackProvider.updateTrackMetadata(track));
  };
  _markStartup('播放栈（含媒体会话）', startup);
  // 资料库 provider（收藏/历史/列表）：AI 推歌、托盘、Provider 树共用。
  final libraryProvider = LibraryProvider(
    repository: library.libraryRepository,
    playbackProvider: playback.playbackProvider,
  );
  // 当前渠道的唯一所有者：发现内容与搜索共用，持久化 / 跨设备重载 /
  // 失效回退规则都在模块内（页面与 Ctrl+F 不再手工同步两份渠道）。
  late final ChannelSelection channelSelection;
  final channelSettings = catalog.settings.mount(
    SettingsModule(
      keys: [kDiscoverChannelKey],
      reload: () => channelSelection.reloadFromPreferences(),
    ),
  );
  channelSelection = ChannelSelection(
    settings: channelSettings,
    validKeys: () {
      final manager = catalog.sourceManager;
      // 音源未初始化 / 脚本激活中时有效集合为空：不允许回退，否则会覆盖
      // 用户保存的脚本渠道偏好。
      if (!manager.initialized || manager.isActivating) return const [];
      return [
        for (final channel in manager.channels)
          if (channel.enabled) channel.key,
      ];
    },
    defaultKey: () => BuiltinDiscover.sourceKeys.first,
  );
  // 搜索 provider 由组合根创建（原先在 Provider 树里懒建）：只为了在创建时
  // 注册托盘期的缓存释放回调；挂树仍是同一个实例（`provider_tree.dart`）。
  final searchHistoryStore = SearchHistoryStore();
  await searchHistoryStore.ready();
  final searchProvider = SearchProvider(
    playback.playbackProvider,
    selection: channelSelection,
    catalogService: catalog.catalogService,
    sourceRegistry: catalog.sourceRegistry,
    historyStore: searchHistoryStore,
  );
  // 系统媒体会话的「收藏」动作：通知点击 ↔ 曲库（与托盘 / 任务栏按钮同一
  // 写入路径）。必须在 provider 建好之后接线（handler 先于它创建）。
  wireNotificationFavorite(
    audioHandler: playback.audioHandler,
    libraryProvider: libraryProvider,
  );
  // 全局热键（系统级，默认关）：注册是启动期副作用、不依赖首帧，runApp 前
  // 注册好让窗口一出现热键即可用（含冷启动恢复态）；命令执行器用刚建好的
  // 播放 provider 接线——热键回调不依赖 widget 树。注册失败在层内降级，
  // 不阻断启动（见 global_hotkeys.dart）。
  GlobalHotkeys.bindActions(
    ShortcutActions(playback: playback.playbackProvider),
  );
  // 热键注册（平台通道）不参与首帧内容：与桌面壳 / 主题预解析并行推进，
  // 在 runApp 前 await 一次即可（窗口出现时热键已就绪）。
  final hotkeysWatch = Stopwatch()..start();
  final hotkeysFuture = GlobalHotkeys.attach().whenComplete(
    () => markStartupStep('sub.hotkeys.attach', hotkeysWatch),
  );
  // ⑤ 桌面壳（异步：prefs / 托盘落地）与 ⑥ AI 推歌 / ⑦ 歌词会话：
  // 三组互不依赖；桌面壳的异步初始化与后面两组同步装配并行推进
  // （不 await 完桌面壳再开始下一步）。
  final desktopWatch = Stopwatch()..start();
  final desktopFuture = buildDesktopStack(
    playback: playback.playbackProvider,
    libraryProvider: libraryProvider,
    playStatisticsService: library.playStatisticsService,
    // 退出前先让音频设备停下来，再销毁窗口（Windows 上避免爆音）。
    shutdownAudio: playback.localPlaybackService?.shutdownAudioForQuit,
  ).whenComplete(() => markStartupStep('sub.desktop.build', desktopWatch));
  final ai = buildAiStack(
    catalog: catalog,
    library: library,
    playback: playback.playbackProvider,
    libraryProvider: libraryProvider,
  );
  final lyrics = buildLyricsStack(local: local);
  wireBiliLoginLyricsRefresh(
    account: catalog.biliAccount,
    sourceManager: catalog.sourceManager,
    lyricsProvider: lyrics.lyricsProvider,
  );
  // ⑧ 歌词显示与主题（含 runApp 前的启动预解析：首帧即封面色）。
  // 与桌面壳并行：两者互不依赖，串行会白等 tray settings 的 prefs 读取。
  final displayWatch = Stopwatch()..start();
  final displayFuture = buildLyricsDisplayStack(
    catalog: catalog,
    playback: playback.playbackProvider,
    lyricsProvider: lyrics.lyricsProvider,
    audioHandler: playback.audioHandler,
    powerPolicy: powerPolicy,
    customCovers: local.customCovers,
  );
  final desktop = await desktopFuture;
  final display = await displayFuture;
  markStartupStep('sub.lyricsDisplay.build', displayWatch);
  _markStartup('主题/歌词显示', startup);
  // 热键注册与上面的装配并行；runApp 前确保就绪（含冷启动恢复态）。
  await hotkeysFuture;
  // ⑨ 听歌统计接线（纯观察者：快照 + 进度 tick）。
  wirePlayStatistics(
    playback: playback.playbackProvider,
    service: library.playStatisticsService,
  );
  // ⑩ 跨设备同步（可选子系统；引擎 init / 调度器启动后移到首帧，见
  //    post_frame_init.dart 的 startSync）。
  final sync = await buildSyncStack(
    catalog: catalog,
    library: library,
    playback: playback,
    dataSaver: local.dataSaver,
    customCovers: local.customCovers,
    // 配对发现只在前台应答：生命周期判定留在组合根，数据层不碰 WidgetsBinding。
    isForeground: () =>
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
  );
  _markStartup('同步栈', startup);
  // 托盘期 / 系统低内存时释放可重建的业务缓存（不动收藏、历史、脚本与
  // 当前播放队列）：搜索结果是本次会话的瞬时数据；列表曲目与目录分页页
  // 退出后按需重取；内置平台响应 / 原生取词取图 / 封面补取 / 统计导出
  // 都是可重读的派生缓存，同步轮次的收集与快照缓存也只在轮间复用。
  // 普通退后台不释放（恢复时会空列表），只有托盘隐藏与系统低内存才触发。
  // 只注册释放入口，AppMemoryManager 不反向依赖这些类型。
  final reclaimableCaches = <void Function()>[
    libraryProvider.releaseBrowseCaches,
    searchProvider.releaseSearchResults,
    catalog.catalogService.clearSearchCache,
    catalog.albumService.clearCache,
    catalog.artistService.clearCache,
    catalog.commentsService.clearCache,
    library.statisticsSyncStore.releaseExportCaches,
    BuiltinSearch.clearCachedResponses,
    catalog.sourceManager.releaseBuiltinLyricCache,
    catalog.sourceManager.releaseBuiltinPicCache,
    local.coverBackfill.clearCache,
    sync.engine.releaseIdleCaches,
  ];
  for (final releaser in reclaimableCaches) {
    AppMemoryManager.instance
      ..addReleaser(releaser)
      ..addLowMemoryReleaser(releaser);
  }
  // ⑪ 应用内更新（纯构造；包信息 / 偏好 / 平台信息读取后移到首帧）。
  final update = buildUpdateStack(quitApp: desktop.quitApp);
  _markStartup('更新栈（装配完成）', startup);

  // 诊断导出器：设置 / 渠道 / 数据库 / 更新信息由注入的 gatherer 读取；
  // 日志读取、脱敏与组装在后台 isolate 完成。未打开诊断页时不执行。
  final diagnosticsExporter = DiagnosticsExporter(
    service: diagnostics.service,
    appInfo: DiagnosticsAppInfoGatherer(
      updateChannel: () => update.provider.channel.wireName,
      updateAutoCheck: () => update.provider.autoCheckEnabled,
    ),
    settings: () => gatherDiagnosticsSettings(
      registry: catalog.settings,
      sync: _diagnosticsSyncInfo(sync.provider.state),
      extraValues: {
        'data_saver_enabled': local.dataSaver.enabled,
        'data_saver_active': local.dataSaver.active,
        'data_saver_quality_cap': local.dataSaver.qualityCap,
        'data_saver_covers': local.dataSaver.coversSaverEnabled,
        'update_channel': update.provider.channel.wireName,
        'update_auto_check': update.provider.autoCheckEnabled,
      },
    ),
    sources: () async => gatherDiagnosticsSources(catalog.sourceManager),
    database: gatherDiagnosticsDatabaseCounts,
    logDirectory: diagnostics.logSink.directory,
  );

  // 应用生命周期扇出的唯一 owner：main 只把系统事件转进来，同步 / 会话 /
  // 统计 / 网络 / 更新的反应由各子系统注册，不再由 main 与 app_shell
  // 各持一份 WidgetsBindingObserver 分散触发。
  final appLifecycle = AppLifecycleCoordinator()
    ..register(
      AppLifecycleParticipant(
        onResumed: sync.provider.onAppResumed,
        onHidden: sync.provider.onAppHidden,
      ),
    )
    ..register(
      AppLifecycleParticipant(onResumed: update.provider.handleAppResumed),
    )
    ..register(
      AppLifecycleParticipant(onResumed: local.dataSaver.refreshConnectivity),
    )
    ..register(
      AppLifecycleParticipant(
        // 会话提交与统计落盘只认 paused：桌面 hide / 托盘隐藏不提交会话
        // （移动端 paused 已由 PlaybackPowerPolicy 触发协调者落盘）。
        onPaused: () async {
          if (!mobilePowerPolicy) {
            await playback.playbackProvider.suspendPlaybackSession();
          }
          await library.playStatisticsService.flush();
        },
      ),
    );

  // 前台恢复：拉一次（有本地变更时一并推送）并复查更新安装权限——从
  // 「安装未知应用」系统授权页返回后要把按钮从「去授权」切回「立即安装」；
  // 退后台 / 锁屏：同步调度器取消全部定时器并尽力推一次。
  // 连续滑杆 / 封面 seed 用的是防抖写：窗口不可见或退后台前补一次，
  // 避免用户拖完就关窗口时丢掉最后一段（派生缓存丢得起，设置 JSON 不该丢）。
  void flushDeferredWrites() {
    unawaited(display.lyricsDisplaySettings.flushPersistence());
    unawaited(display.artworkPaletteService.flushSeedCache());
  }

  // 移动端前后台同时喂 `PlaybackPowerPolicy`（桌面不接：托盘 / 最小化另有
  // `AppPresence`，且桌面播放保持前台节拍）；`onPause` / `onHide` 都先走
  // 同一套「收后台工作」，只有 paused 额外触发会话提交 / 统计落盘。
  void onAppBackground({bool paused = false}) {
    flushDeferredWrites();
    if (mobilePowerPolicy) {
      powerPolicy.markBackground();
      // 移动端 30s 后回收图片缓存；快速切回时 onAppForeground 会取消。
      // 桌面托盘走 AppPresence，生命周期不触发这里。
      AppMemoryManager.instance.onAppBackground();
    }
    unawaited(appLifecycle.hidden());
    if (paused) unawaited(appLifecycle.paused());
  }

  // 桌面托盘 / 最小化不一定走 `AppLifecycleState`：窗口层置位 `AppPresence`
  // 时也补一次；`minimized` 同样算不可见（用户随时可能从任务栏恢复）。
  AppPresence.instance.addListener(() {
    if (!AppPresence.instance.isVisible) flushDeferredWrites();
  });

  // 托盘内暂停后补一次 trim：播放中暂停会让音频 / 解码线程把页重新触回
  // 工作集，暂停稳定后再归还；播放恢复 / 窗口可见时取消。
  Future<void> releaseIdlePlayer() =>
      playback.localPlaybackService?.releasePlayerForIdle() ?? Future.value();
  var lastPlaying = playback.playbackProvider.isPlaying;
  var lastTrackId = playback.playbackProvider.snapshot.current?.id.uri;
  void syncTrayTrimTimers() {
    final playing = playback.playbackProvider.isPlaying;
    final trackId = playback.playbackProvider.snapshot.current?.id.uri;
    final playingChanged = playing != lastPlaying;
    final trackChanged = trackId != lastTrackId;
    lastPlaying = playing;
    lastTrackId = trackId;
    if (playingChanged) {
      if (playing) {
        AppMemoryManager.instance.cancelTrayPausedTrim();
      } else if (AppPresence.instance.isTrayHidden) {
        AppMemoryManager.instance.scheduleTrayPausedTrim(
          onIdle: releaseIdlePlayer,
        );
      }
    }
    if (trackChanged && AppPresence.instance.isTrayHidden) {
      AppMemoryManager.instance.scheduleTrayTrackChangeTrim();
    }
  }

  playback.playbackProvider.addListener(syncTrayTrimTimers);
  AppPresence.instance.addListener(() {
    if (AppPresence.instance.isTrayHidden) {
      if (!playback.playbackProvider.isPlaying) {
        AppMemoryManager.instance.scheduleTrayPausedTrim(
          onIdle: releaseIdlePlayer,
        );
      }
    } else {
      AppMemoryManager.instance
        ..cancelTrayPausedTrim()
        ..cancelTrayTrackChangeTrim();
    }
  });

  AppLifecycleListener(
    // macOS Cmd+Q / Linux 应用级 quit 与托盘「退出」走同一条落盘路径：
    // 空闲时先取消系统终止、启动 quitApp；进入销毁阶段后放行原生终止。
    onExitRequested: () async => desktop.handleExitRequest(),
    onResume: () {
      if (mobilePowerPolicy) {
        powerPolicy.markForeground();
        AppMemoryManager.instance.onAppForeground();
      }
      unawaited(appLifecycle.resumed());
    },
    onPause: () => onAppBackground(paused: true),
    onHide: onAppBackground,
    // 进程销毁：关掉文件日志（有界刷盘），不影响系统回收速度。
    onDetach: () => unawaited(diagnostics.service.dispose()),
  );

  runApp(
    MultiProvider(
      providers: buildAppProviders(
        catalog: catalog,
        local: local,
        library: library,
        playback: playback,
        libraryProvider: libraryProvider,
        channelSelection: channelSelection,
        searchProvider: searchProvider,
        searchHistoryStore: searchHistoryStore,
        desktop: desktop,
        ai: ai,
        lyrics: lyrics,
        display: display,
        sync: sync,
        update: update,
        diagnosticsService: diagnostics.service,
        diagnosticsExporter: diagnosticsExporter,
        notifications: notifications,
      ),
      child: MyThemedApp(
        // 用户交互 → 同步调度器续期活跃窗口（最近交互判定）。
        onUserInteraction: sync.provider.notifyInteraction,
      ),
    ),
  );

  // 首帧：先亮窗口（内容已画好，用户不再盯空白窗），再做启动尾巴
  // （托盘落地 + 更新准备/自动检查 + 同步启动 + 音源初始化）。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    revealFallback.cancel();
    _markStartup('首帧', startup);
    FrameStats.instance.reportNow('first-frame');
    unawaited(WindowChrome.show());
    initAfterFirstFrame(
      catalog: catalog,
      local: local,
      library: library,
      desktop: desktop,
      ai: ai,
      update: update,
      sync: sync,
    );
    // 数据链路体检（仅 MOLIA_PERF_SCENARIO_DATA=true 的专用构建；正常包
    // 在编译期折叠为一次 return）。
    unawaited(
      runDataPathScenario(catalog: catalog, playback: playback, lyrics: lyrics),
    );
  });
}
