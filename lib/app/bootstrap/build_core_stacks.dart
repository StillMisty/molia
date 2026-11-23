/// 核心栈：目录 / 主库预热 → 本地数据与资料库（并行）→ 播放 → 渠道 / 搜索。
///
/// 顺序不变量：
/// - 主库预热与本地数据 / 资料库并行，播放会话首帧前要能读到恢复态；
/// - 播放栈在本地 / 资料库之后、系统媒体会话之前装配；
/// - 标题编辑的会话 gate 在播放栈之后接线；
/// - 通知收藏 / 热键在 provider 建好后接线。
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../../data/diagnostics/source_health_probe.dart';
import '../../data/molia_database.dart';
import '../../playback/local_audio_handler.dart';
import '../../providers/library_provider.dart';
import '../../services/diagnostics/source_health_checker.dart';
import 'app_dependencies.dart';
import 'app_ui_messenger.dart';
import 'catalog_stack.dart';
import 'library_stack.dart';
import 'local_data_stack.dart';
import 'playback_stack.dart';
import 'scrobble_stack.dart';
import 'source_engine_recovery.dart';
import 'startup_trace.dart';
import 'wiring/observers_wiring.dart';

/// 启动期主库预热失败的告警（与阶段行同一 logger，release 也输出）。
final _startupLog = Logger('molia.startup');

/// 装配 runApp 前必须就绪的核心业务栈。
Future<CoreStacks> buildCoreStacks({
  required PlatformBootstrap platform,
}) async {
  final startup = platform.startup;
  final diagnostics = platform.diagnostics;

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
  markStartupStep('本地数据/资料库栈', startup);
  // 音源引擎随网络恢复自愈：断网把引擎打进 failed 后，换网 / 重连事件是
  // 比 UI 重试按钮更可靠的恢复时机（组合根持有订阅，进程销毁时取消）。
  final sourceEngineRecovery = SourceEngineNetworkRecovery(
    sourceManager: catalog.sourceManager,
    networkEvents: local.dataSaver.networkEvents,
  );
  // 听歌同步：纯构造（不读凭据库）；服务在首帧后 init，页面打开时再补一次。
  final scrobble = buildScrobbleStack(settings: catalog.settings);
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
    messenger: AppUiMessenger(platform.notifications),
    powerPolicy: platform.powerPolicy,
    failures: diagnostics.failures,
    attempts: diagnostics.service.attempts,
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
  markStartupStep('播放栈（含媒体会话）', startup);
  // 资料库 provider（收藏/历史/列表）：AI 推歌、托盘、Provider 树共用。
  final libraryProvider = LibraryProvider(
    repository: library.libraryRepository,
    playbackProvider: playback.playbackProvider,
  );
  // 当前渠道与搜索 provider 由组合根创建：托盘期缓存释放回调注册在同一个
  // 实例上，随后登记进 Riverpod 容器（见 `runtime_wiring.dart`）。
  final channelSearch = buildChannelSearchRuntime(
    catalog: catalog,
    playback: playback,
  );
  // 系统媒体会话的「收藏」动作：通知点击 ↔ 曲库（与托盘 / 任务栏按钮同一
  // 写入路径）。必须在 provider 建好之后接线（handler 先于它创建）。
  wireNotificationFavoriteAction(
    playback: playback,
    libraryProvider: libraryProvider,
  );
  // 全局热键（系统级，默认关）：注册是启动期副作用、不依赖首帧，runApp 前
  // 注册好让窗口一出现热键即可用（含冷启动恢复态）；attach 与后续桌面壳 /
  // 主题预解析并行推进，runApp 前 await 一次。
  final hotkeysFuture = startGlobalHotkeys(playback: playback);

  return (
    catalog: catalog,
    local: local,
    library: library,
    playback: playback,
    scrobble: scrobble,
    libraryProvider: libraryProvider,
    channelSelection: channelSearch.channelSelection,
    searchProvider: channelSearch.searchProvider,
    sourceEngineRecovery: sourceEngineRecovery,
    hotkeysFuture: hotkeysFuture,
  );
}
