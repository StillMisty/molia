/// 播放栈：本地播放链路（just_audio，见 `local_playback_chain.dart`）→
/// PlaybackEngine → PlaybackSessionCoordinator → PlaybackProvider，
/// 含播放副作用观察者与系统媒体会话。
///
/// **前向引用如何拆开**：
/// - 服务 ↔ 后端互为依赖（服务要解析直链、后端要控制服务）。「取链」是一条
///   解析函数（`LocalPlaybackChain`），两个消费者都不引用对方实例，无需
///   `late final` 式的前置引用。
/// - 系统媒体会话在会话模块建好之后装配：恢复态切歌键与系统控制落盘都落到
///   `PlaybackSessionCoordinator`，不需要可变的回填槽位。会话仍由注入的
///   [buildPlaybackStack] 参数构建，调用点仍在 `runApp` 之前。
library;

import '../../domain/ports/playback_facade.dart';
import '../../domain/ports/ui_messenger.dart';
import '../../data/settings/settings_keys.dart';
import '../../data/settings/settings_module.dart';
import '../../data/settings/settings_registry.dart';
import '../../playback/local_audio_handler.dart';
import '../../playback/local_playback_service.dart';
import '../../playback/playback_power_policy.dart';
import '../../playback/playback_session_coordinator.dart';
import '../../providers/playback_provider.dart';
import '../../providers/sleep_timer.dart';
import '../../services/audio_focus_settings.dart';
import '../../services/diagnostics/failure_ring_buffer.dart';
import '../../services/playback_observer.dart';
import '../../services/playback_recent_tracks.dart';
import '../../services/playback_session_store.dart';
import '../app_shell.dart';
import 'catalog_stack.dart';
import 'library_stack.dart';
import 'local_data_stack.dart';
import 'local_playback_chain.dart';
import 'startup_trace.dart';

/// 系统媒体会话装配（flutter_media_session / Linux MPRIS，见 ADR-0010）：
/// 真实本地播放服务链路与会话模块都就绪后调用；恢复态（冷启动未起播）的
/// 切歌键落到会话模块，由它按阶段路由（恢复播放 / 转发 facade）。
typedef MediaSessionFactory = Future<LocalAudioHandler?> Function(
  LocalPlaybackService service,
  PlaybackSessionCoordinator session,
);

/// 播放栈产物（构造顺序见 [buildPlaybackStack]）。
///
/// [localPlaybackService] 仅在构建真实 just_audio 链路时非空——注入
/// `facade` seam（测试）时没有真实服务，媒体会话也随之跳过。
typedef PlaybackStack = ({
  /// 组合根的注册表（与 catalog / library 同一实例；组合根测试据此核对
  /// 「唯一注册表」）。
  SettingsRegistry settings,
  LocalPlaybackService? localPlaybackService,
  PlaybackFacade facade,
  PlaybackObserver observer,
  PlaybackProvider playbackProvider,
  LocalAudioHandler? audioHandler,

  /// 实时会话存储（同步栈据此标记「会话待外发」）。
  PlaybackSessionStore sessionStore,

  /// 播放会话模块（同步栈经它应用远端会话，生产唯一的会话写队列）。
  PlaybackSessionCoordinator sessionCoordinator,

  /// 音频焦点偏好（设置 › 播放；播放服务与设置页共用同一实例）。
  AudioFocusSettings audioFocusSettings,
});

/// 装配本地播放链路、播放 provider 与系统媒体会话。
///
/// [facade] 与 [mediaSessionFactory] 是测试 seam：前者给假播放引擎（不加载
/// just_audio 插件），后者传 null 跳过音频会话初始化；生产由 `main()` 注入
/// `initSystemMediaSession`。
///
/// [powerPolicy] 是组合根创建的唯一实例（移动端前后台 / 桌面歌词状态），
/// 同时传给播放服务与会话模块；测试省略时退化为前台实例。
Future<PlaybackStack> buildPlaybackStack({
  required CatalogStack catalog,
  required LocalDataStack local,
  required LibraryStack library,
  required UiMessenger messenger,
  MediaSessionFactory? mediaSessionFactory,
  PlaybackFacade? facade,
  PlaybackPowerPolicy? powerPolicy,
  FailureRecorder? failures,
}) async {
  final sourceManager = catalog.sourceManager;
  final dataSaver = local.dataSaver;
  final policy = powerPolicy ?? PlaybackPowerPolicy();
  final covers = local.customCovers;
  // 智能随机的「最近听过」证据：统计优先、历史兜底，播放层只拿到 id 集合。
  final recentTracks = PlaybackRecentTracks(
    statistics: library.playStatisticsRepository,
    history: library.libraryRepository,
    statisticsEnabled: () => library.playStatisticsService.enabled,
  );

  // 音频焦点偏好必须在建播放器之前读好：默认开（与其他应用同时播放），
  // 但用户可能已关闭；首次中断不应按错的策略处理。
  late final AudioFocusSettings audioFocusSettings;
  final audioFocusScope = catalog.settings.mount(
    SettingsModule(
      keys: [kPlayWithOtherApps],
      reload: () => audioFocusSettings.init(),
    ),
  );
  audioFocusSettings = AudioFocusSettings(settings: audioFocusScope);
  await audioFocusSettings.init();

  final LocalPlaybackService? localPlaybackService;
  final PlaybackFacade playbackFacade;
  final injectedFacade = facade;
  if (injectedFacade != null) {
    // 测试 / 特殊宿主：外部给播放引擎，其余接线（观察者 / provider / 媒体
    // 会话 seam）与生产完全同构。
    localPlaybackService = null;
    playbackFacade = injectedFacade;
  } else {
    final chain = LocalPlaybackChain(
      catalog: catalog,
      local: local,
      powerPolicy: policy,
    );
    final service = chain.buildService(
      playWithOtherApps: audioFocusSettings,
      recentTrackIds: recentTracks.recentTrackIds,
    );
    localPlaybackService = service;
    playbackFacade = chain.buildEngine(service: service);
  }

  // 播放观察者：快照副作用扇出（最后播放 / 桌面小组件 / 历史 / 封面预取与
  // 补取 / 通知权限）。先建观察者，provider 创建后再挂接——facade 监听顺序
  // 保持「会话模块先做恢复态交接、provider/观察者后写副作用」。
  // 默认仓库 = 主库 `MoliaDatabase.instance`（测试经 store 的 debug override
  // 注入内存库）；不在这里另建 repository，避免绕过测试缝。
  final sessionStore = PlaybackSessionStore();
  final playbackObserver = PlaybackObserver(
    facade: playbackFacade,
    dataSaver: dataSaver,
    libraryRepository: library.libraryRepository,
    navigatorKey: navigatorKey,
    // 移动端退后台不预取封面（应用内没有展示面）；桌面仍由 AppPresence
    // 管托盘 / 最小化，两条信号互不覆盖。
    mobilePowerPolicy: policy,
    // 封面补取：曲目起播无封面时先走本渠道原生取图，失败后按名字跨渠道
    // 严格匹配兜底；省流模式不发请求。取到后原地回写队列曲目。
    artworkResolver: (track) async {
      if (dataSaver.blockNetworkArtwork) return null;
      return local.coverBackfill.fetch(track);
    },
    coverResolver: covers.resolution,
  );
  // 播放会话模块：恢复态 ↔ live 交接 + 会话落盘唯一写者。组合根创建共享
  // 存储（同步栈也用同一实例标记「会话待外发」）并注入，恢复曲目的「最后
  // 播放」展示接观察者；同步栈拿到的是这个协调者（远端应用 / 删除同样走
  // 它持有的写队列），不再另建 store。
  //
  // 两个播放偏好共用一个挂载点，但重载路径不同：默认播放模式只重读模式，
  // 恢复开关要联动恢复态交接（钩子挂在 provider 上——协调者只报告「恢复态
  // 是否变化」，UI 通知由 provider 发）。
  late final PlaybackProvider playbackProvider;
  final playbackSettings = catalog.settings.mount(
    SettingsModule.withReloads(
      keys: [kDefaultPlayMode, kRestoreSessionEnabled],
      reloads: [
        (
          keys: [kDefaultPlayMode],
          reload: () => playbackProvider.reloadDefaultPlayMode(),
        ),
        (
          keys: [kRestoreSessionEnabled],
          reload: () => playbackProvider.reloadRestoreSessionPreference(),
        ),
      ],
    ),
  );
  final sessionCoordinator = PlaybackSessionCoordinator(
    facade: playbackFacade,
    store: sessionStore,
    settings: playbackSettings,
    onRestoredTrack: playbackObserver.showRestoredTrack,
    powerPolicy: policy,
    // 恢复态的洗牌与真实播放同一套证据 / 开关（provider 已构造完成，
    // load() 的异步读取发生在其后，读到的是加载后的设置）。
    recentTrackIds: recentTracks.recentTrackIds,
    smartShuffleEnabled: () => playbackProvider.smartShuffleEnabled,
  );
  playbackProvider = PlaybackProvider(
    settings: playbackSettings,
    facade: playbackFacade,
    messenger: messenger,
    sourceManager: sourceManager,
    catalogService: catalog.catalogService,
    dataSaver: dataSaver,
    observer: playbackObserver,
    sessionCoordinator: sessionCoordinator,
    // 定时关闭的原生 wake lock 只在移动端后台 / 息屏时持有。
    isForeground: () => policy.isForeground,
    autoSwapSettings: library.sourceSwapSettings,
    autoSwapResolver: (track, {required excludeSourceKeys}) => library
        .autoSourceSwapService
        .findMatch(track, excludeSourceKeys: excludeSourceKeys),
    onAutoSourceSwapped: covers.carryOver,
    failures: failures,
  );
  playbackObserver.attach();

  // 定时关闭补检：熄屏 / 后台时 Dart 定时器可能被节流或整段冻结，
  // 回到前台时按绝对 deadline 补触发（语义见 `providers/sleep_timer.dart`）。
  // 与 App 同生命周期，不单独释放。
  SleepTimerLifecycleRecheck(playbackProvider.sleepTimer).attach();

  // 系统媒体会话必须在 runApp 之前初始化，并复用同一个本地播放服务实例；
  // 平台不支持或初始化失败时工厂返回 null，自动降级为应用内播放。
  // 省流时通知/锁屏封面置空（artworkBlocked 在 main 注入的工厂里接线），
  // 不让平台为通知下载封面。
  LocalAudioHandler? audioHandler;
  final service = localPlaybackService;
  final factory = mediaSessionFactory;
  if (service != null && factory != null) {
    final mediaSessionWatch = Stopwatch()..start();
    // 系统控制（通知 / 锁屏 / 耳机键）经 handler 翻译成会话命令：暂停 / 停止 /
    // 切播放顺序 / seek 的 stage 路由与「返回前已落盘」由协调者负责，这里不再
    // 回填第二个落盘回调。
    audioHandler = await factory(service, sessionCoordinator);
    markStartupStep('sub.mediaSession.activate', mediaSessionWatch);
  }

  // 自定义 / 默认封面变化：系统媒体元数据与桌面小组件立即跟上；主题取色
  // 由 lyrics_display_stack 订阅同一变更信号，界面由 `TrackArtwork` 统一
  // 刷新。远端同步落地的封面也走同一回调（解析器的变更信号不区分本地 /
  // 远端）。
  covers.resolution.addChangeListener(() {
    audioHandler?.refreshArtwork();
    playbackObserver.refreshCoverPresentation();
  });

  return (
    settings: catalog.settings,
    localPlaybackService: localPlaybackService,
    facade: playbackFacade,
    observer: playbackObserver,
    playbackProvider: playbackProvider,
    audioHandler: audioHandler,
    sessionStore: sessionStore,
    sessionCoordinator: sessionCoordinator,
    audioFocusSettings: audioFocusSettings,
  );
}
