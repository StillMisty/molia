import 'dart:async';
import 'dart:io' show exit;

import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app/app_shell.dart';
import 'app/bootstrap/ai_stack.dart';
import 'app/bootstrap/app_ui_messenger.dart';
import 'app/bootstrap/catalog_stack.dart';
import 'app/bootstrap/desktop_stack.dart';
import 'app/bootstrap/library_stack.dart';
import 'app/bootstrap/local_data_stack.dart';
import 'app/bootstrap/lyrics_display_stack.dart';
import 'app/bootstrap/lyrics_stack.dart';
import 'app/bootstrap/playback_stack.dart';
import 'app/bootstrap/post_frame_init.dart';
import 'app/bootstrap/provider_tree.dart';
import 'app/bootstrap/sync_stack.dart';
import 'app/bootstrap/update_stack.dart';
import 'playback/desktop_audio_init.dart';
import 'playback/local_audio_handler.dart';
import 'providers/library_provider.dart';
import 'services/app_logging.dart';
import 'services/notification_service.dart';
import 'services/window/single_instance.dart';
import 'services/window/window_chrome.dart';
import 'services/window/window_settings.dart';

/// 启动耗时埋点（见 `main()` 顶部）：单行日志，release 也输出，
/// 便于「启动迟缓」回归时一眼定位阶段。
final _startupLog = Logger('molia.startup');

void _markStartup(String stage, Stopwatch watch) =>
    _startupLog.info('$stage：${watch.elapsedMilliseconds}ms');

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

  // 日志装配（package:logging 的 handler / level 只在这里和测试配置里设一次）
  initAppLogging();

  // 窗口行为偏好（设备本地）：窗口几何的恢复/保存在建窗之前就要判定，
  // 因此先 await 载入一次（读取失败保持默认开启）。
  await WindowSettings.load();

  // 强制单实例（桌面）：已有实例在跑 → 请它显示主窗口后立即退出；此刻
  // 窗口还没创建，不会闪一下再消失。其余平台 / 抢锁异常按主实例继续。
  if (await SingleInstance.acquire() == SingleInstanceRole.secondary) {
    exit(0);
  }

  // 桌面窗口 chrome（Linux/Windows）：隐藏原生标题栏并恢复几何，**先不显示**
  // （其余平台是空操作）。窗口在首帧回调里才亮出来——见 `window_chrome_io`
  // 的 ensureInitialized 注释（先显示会让用户盯空白窗等待装配）。
  await WindowChrome.ensureInitialized();
  // 显示兜底：首帧回调是主路径；装配异常 / 卡住时窗口也必须出现（show 幂等）。
  final revealFallback = Timer(
    const Duration(seconds: 5),
    () => unawaited(WindowChrome.show()),
  );
  _markStartup('窗口就绪', startup);

  // 桌面端本地播放后端（Windows/Linux: media_kit）
  initDesktopAudioIfNeeded();

  // 提示出口（纯构造，无插件、无 await）：播放 provider 的 UiMessenger
  // 与 Provider 树共用同一实例。
  final notifications = NotificationService(
    scaffoldMessengerKey,
    hostContextKey: appRootKey,
  );

  // ① 音源与目录（设置注册表 → SourceManager → 目录/评论/专辑/歌手）。
  final catalog = buildCatalogStack();
  // ② 本地数据（省流 + 封面网关 + 下载链路 + 歌词服务 + 缓存写入器）。
  final local = await buildLocalDataStack(catalog: catalog);
  // ③ 资料库 / 统计 / 换源偏好（设备戳在 syncState 就绪后可用）。
  final library = await buildLibraryStack(catalog: catalog);
  _markStartup('本地数据/资料库栈', startup);
  // ④ 播放链路 + provider + 观察者 + 系统媒体会话。
  final playback = await buildPlaybackStack(
    catalog: catalog,
    local: local,
    library: library,
    messenger: AppUiMessenger(notifications),
    mediaSessionFactory: (service, provider) => initSystemMediaSession(
      service,
      artworkBlocked: () => local.dataSaver.blockNetworkArtwork,
      onRestoredSkipToNext: provider.skipToNext,
      onRestoredSkipToPrevious: provider.skipToPrevious,
    ),
  );
  _markStartup('播放栈（含媒体会话）', startup);
  // 资料库 provider（收藏/历史/列表）：AI 推歌、托盘、Provider 树共用。
  final libraryProvider = LibraryProvider(
    repository: library.libraryRepository,
    playbackProvider: playback.playbackProvider,
  );
  // ⑤ 桌面壳（异步：prefs / 托盘落地）与 ⑥ AI 推歌 / ⑦ 歌词会话：
  // 三组互不依赖；桌面壳的异步初始化与后面两组同步装配并行推进
  // （不 await 完桌面壳再开始下一步）。
  final desktopFuture = buildDesktopStack(
    playback: playback.playbackProvider,
    libraryProvider: libraryProvider,
    playStatisticsService: library.playStatisticsService,
  );
  final ai = buildAiStack(
    catalog: catalog,
    library: library,
    playback: playback.playbackProvider,
    libraryProvider: libraryProvider,
  );
  final lyrics = buildLyricsStack(local: local);
  final desktop = await desktopFuture;
  // ⑧ 歌词显示与主题（含 runApp 前的启动预解析：首帧即封面色）。
  final display = await buildLyricsDisplayStack(
    catalog: catalog,
    playback: playback.playbackProvider,
    lyricsProvider: lyrics.lyricsProvider,
    audioHandler: playback.audioHandler,
  );
  _markStartup('主题/歌词显示', startup);
  // ⑨ 听歌统计接线（纯观察者：快照 + 进度 tick）。
  wirePlayStatistics(
    playback: playback.playbackProvider,
    service: library.playStatisticsService,
  );
  // ⑩ 跨设备同步（可选子系统；初始化失败不阻断启动）。
  final sync = await buildSyncStack(
    catalog: catalog,
    library: library,
    playback: playback,
    dataSaver: local.dataSaver,
  );
  _markStartup('同步栈', startup);
  // ⑪ 应用内更新（渠道 / 自动检查 / 下载安装；退出走统一路径）。
  final update = await buildUpdateStack(quitApp: desktop.quitApp);
  _markStartup('更新栈（装配完成）', startup);

  // 前台恢复：拉一次（有本地变更时一并推送）并复查更新安装权限——从
  // 「安装未知应用」系统授权页返回后要把按钮从「去授权」切回「立即安装」；
  // 退后台 / 锁屏：同步调度器取消全部定时器并尽力推一次。
  AppLifecycleListener(
    onResume: () {
      sync.provider.onAppResumed();
      unawaited(update.provider.handleAppResumed());
    },
    onPause: sync.provider.onAppHidden,
    onHide: sync.provider.onAppHidden,
  );

  runApp(
    MultiProvider(
      providers: buildAppProviders(
        catalog: catalog,
        local: local,
        library: library,
        playback: playback,
        libraryProvider: libraryProvider,
        desktop: desktop,
        ai: ai,
        lyrics: lyrics,
        display: display,
        sync: sync,
        update: update,
        notifications: notifications,
      ),
      child: MyThemedApp(
        // 用户交互 → 同步调度器续期活跃窗口（最近交互判定）。
        onUserInteraction: sync.provider.notifyInteraction,
      ),
    ),
  );

  // 首帧：先亮窗口（内容已画好，用户不再盯空白窗），再做启动尾巴
  // （托盘落地 + 自动更新检查 + 音源初始化）。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    revealFallback.cancel();
    _markStartup('首帧', startup);
    unawaited(WindowChrome.show());
    initAfterFirstFrame(
      catalog: catalog,
      desktop: desktop,
      update: update,
      syncProvider: sync.provider,
    );
  });
}
