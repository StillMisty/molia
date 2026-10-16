/// 播放栈：本地播放链路（just_audio，见 `local_playback_chain.dart`）→
/// DefaultPlaybackFacade → PlaybackProvider，含播放副作用观察者与系统媒体会话。
///
/// **前向引用如何消失**：
/// - 服务 ↔ 后端互为依赖（服务要解析直链、后端要控制服务）。原组合根用
///   `late final playbackBackend` 让服务解析回调提前引用后端；这里「取链」是
///   一条解析函数（`LocalPlaybackChain`），两个消费者都不引用对方实例。
/// - 系统媒体会话在 provider 建好之后装配：恢复态切歌键回调直接落到 provider，
///   原组合根的 `restoredControlsTarget` 可变槽位（先建 handler 再回填）消失。
///   会话仍由注入的 [buildPlaybackStack] 参数构建，调用点仍在 `runApp` 之前。
library;

import '../../domain/ports/playback_backend.dart';
import '../../domain/ports/playback_facade.dart';
import '../../domain/ports/ui_messenger.dart';
import '../../data/mapping/track_mapper.dart';
import '../../data/playback/default_playback_facade.dart';
import '../../playback/local_audio_handler.dart';
import '../../playback/local_playback_service.dart';
import '../../providers/playback_provider.dart';
import '../../providers/sleep_timer.dart';
import '../../services/playback_observer.dart';
import '../../services/playback_session_store.dart';
import '../app_shell.dart';
import 'catalog_stack.dart';
import 'library_stack.dart';
import 'local_data_stack.dart';
import 'local_playback_chain.dart';

/// 系统媒体会话装配（audio_service 插件绑定）：真实本地播放服务链路与
/// provider 都就绪后调用，恢复态切歌键直接落到 provider。
typedef MediaSessionFactory = Future<LocalAudioHandler?> Function(
  LocalPlaybackService service,
  PlaybackProvider provider,
);

/// 播放栈产物（构造顺序见 [buildPlaybackStack]）。
///
/// [localPlaybackService] 仅在构建真实 just_audio 链路时非空——注入
/// `backend` seam（测试）时没有真实服务，媒体会话也随之跳过。
typedef PlaybackStack = ({
  LocalPlaybackService? localPlaybackService,
  PlaybackFacade facade,
  PlaybackObserver observer,
  PlaybackProvider playbackProvider,
  LocalAudioHandler? audioHandler,
});

/// 装配本地播放链路、播放 provider 与系统媒体会话。
///
/// [backend] 与 [mediaSessionFactory] 是测试 seam：前者给假后端（不加载
/// just_audio 插件），后者传 null 跳过音频会话初始化；生产由 `main()` 注入
/// `initSystemMediaSession`。
Future<PlaybackStack> buildPlaybackStack({
  required CatalogStack catalog,
  required LocalDataStack local,
  required LibraryStack library,
  required UiMessenger messenger,
  MediaSessionFactory? mediaSessionFactory,
  PlaybackBackend? backend,
}) async {
  final sourceManager = catalog.sourceManager;
  final dataSaver = local.dataSaver;

  final LocalPlaybackService? localPlaybackService;
  final PlaybackFacade playbackFacade;
  final injectedBackend = backend;
  if (injectedBackend != null) {
    // 测试 / 特殊宿主：外部给后端，其余接线（观察者 / provider / 媒体会话
    // seam）与生产完全同构。
    localPlaybackService = null;
    playbackFacade = DefaultPlaybackFacade(backend: injectedBackend);
  } else {
    final chain = LocalPlaybackChain(catalog: catalog, local: local);
    final service = chain.buildService();
    localPlaybackService = service;
    playbackFacade =
        DefaultPlaybackFacade(backend: chain.buildBackend(service: service));
  }

  // 播放观察者：快照副作用扇出（最后播放 / 播放上下文 / 桌面小组件 / 历史 /
  // 会话落盘 / 封面预取与补取 / 通知权限）。先建观察者，provider 创建后再
  // 挂接——facade 监听顺序保持「provider 先处理恢复态、观察者后写副作用」。
  // 会话存储两处共用同一实例：恢复态读写在 provider，实时会话节流在观察者。
  final sessionStore = PlaybackSessionStore();
  final playbackObserver = PlaybackObserver(
    facade: playbackFacade,
    sessionStore: sessionStore,
    dataSaver: dataSaver,
    libraryRepository: library.libraryRepository,
    playContextWriter: library.localDatabaseProvider.insertOrUpdatePlayContext,
    navigatorKey: navigatorKey,
    // 封面补取：曲目起播无封面时经 SourceManager 现取（脚本 pic →
    // 内置平台原生取图），省流模式不发请求；取到后原地回写队列曲目。
    artworkResolver: (track) async {
      if (dataSaver.blockNetworkArtwork) return null;
      return sourceManager.fetchPic(sourceTrackFromTrack(track));
    },
  );
  final playbackProvider = PlaybackProvider(
    settings: catalog.settings,
    facade: playbackFacade,
    messenger: messenger,
    sourceManager: sourceManager,
    catalogService: catalog.catalogService,
    dataSaver: dataSaver,
    observer: playbackObserver,
    sessionStore: sessionStore,
    autoSwapSettings: library.sourceSwapSettings,
    autoSwapResolver: (track, {required excludeSourceKeys}) =>
        library.autoSourceSwapService.findMatch(
      track,
      excludeSourceKeys: excludeSourceKeys,
    ),
  );
  playbackObserver.attach();

  // 定时关闭补检：熄屏 / 后台时 Dart 定时器可能被节流或整段冻结，
  // 回到前台时按绝对 deadline 补触发（语义见 `providers/sleep_timer.dart`）。
  // 与 App 同生命周期，不单独释放。
  SleepTimerLifecycleRecheck(playbackProvider.sleepTimer).attach();

  // 系统媒体会话（audio_service）必须在 runApp 之前初始化，并复用同一个
  // 本地播放服务实例；不支持 audio_service 的平台（Linux/Windows/Web）
  // 返回 null，自动降级。省流时通知/锁屏封面置空（artworkBlocked 在 main
  // 注入的工厂里接线），避免 audio_service 为通知下载封面。
  LocalAudioHandler? audioHandler;
  final service = localPlaybackService;
  final factory = mediaSessionFactory;
  if (service != null && factory != null) {
    audioHandler = await factory(service, playbackProvider);
    // 系统控制（通知 / 锁屏 / 耳机键）直接落到播放服务：把暂停 / 停止 /
    // 切播放顺序的会话落盘接到 provider（handler 由注入的工厂创建，回调随后
    // 回填），保证控制动作返回时会话已在本地、重开应用可恢复暂停态。
    audioHandler?.attachSessionPersister(
      playbackProvider.flushPlaybackSession,
    );
  }

  return (
    localPlaybackService: localPlaybackService,
    facade: playbackFacade,
    observer: playbackObserver,
    playbackProvider: playbackProvider,
    audioHandler: audioHandler,
  );
}
