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
import 'services/global_hotkeys.dart';
import 'services/notification_service.dart';
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

  // 窗口行为偏好（设备本地）/ 平台默认 UI 字体 / 单实例锁互不依赖：并行等待
  // （串行是三段相加，并行取最大值）。三者都完成才建窗，语义与拆分前一致。
  //
  // - 窗口几何的恢复/保存在建窗之前就要判定，因此必须 await；
  // - 平台默认字体仅 Windows 读注册表（毫秒级）：未自定义「应用字体」时用它，
  //   保证与系统其它窗口同源（中文系统 = 微软雅黑）；
  // - 单实例（桌面）：已有实例在跑 → 请它显示主窗口后立即退出；此刻窗口还没
  //   创建，不会闪一下再消失。其余平台 / 抢锁异常按主实例继续。
  final (_, _, instanceRole) = await (
    WindowSettings.load(),
    SystemFontsService.loadPlatformDefaultFamily(),
    SingleInstance.acquire(),
  ).wait;
  if (instanceRole == SingleInstanceRole.secondary) {
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
  // ② 本地数据（省流 + 封面网关 + 下载链路 + 歌词服务 + 缓存写入器）
  //    与 ③ 资料库 / 统计 / 换源偏好互不依赖：并行装配，等待取最大值
  //    （串行等待是两段相加，实测该段是启动装配里最大的一块）。
  final (local, library) = await (
    buildLocalDataStack(catalog: catalog),
    buildLibraryStack(catalog: catalog),
  ).wait;
  _markStartup('本地数据/资料库栈', startup);
  // ④ 播放链路 + provider + 观察者 + 系统媒体会话。
  final playback = await buildPlaybackStack(
    catalog: catalog,
    local: local,
    library: library,
    messenger: AppUiMessenger(notifications),
    mediaSessionFactory: (service, session) => initSystemMediaSession(
      service,
      artworkBlocked: () => local.dataSaver.blockNetworkArtwork,
      // 恢复态（冷启动未起播）切歌键落到会话模块：它按阶段决定是恢复播放
      // 还是转发给真实播放。
      onRestoredSkipToNext: () => session.skipToNext(),
      onRestoredSkipToPrevious: () => session.skipToPrevious(),
    ),
  );
  _markStartup('播放栈（含媒体会话）', startup);
  // 资料库 provider（收藏/历史/列表）：AI 推歌、托盘、Provider 树共用。
  final libraryProvider = LibraryProvider(
    repository: library.libraryRepository,
    playbackProvider: playback.playbackProvider,
  );
  // 全局热键（系统级，默认关）：注册是启动期副作用、不依赖首帧，runApp 前
  // 注册好让窗口一出现热键即可用（含冷启动恢复态）；命令执行器用刚建好的
  // 播放 provider 接线——热键回调不依赖 widget 树。注册失败在层内降级，
  // 不阻断启动（见 global_hotkeys.dart）。
  GlobalHotkeys.bindActions(
    ShortcutActions(playback: playback.playbackProvider),
  );
  await GlobalHotkeys.attach();
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
  // ⑩ 跨设备同步（可选子系统；引擎 init / 调度器启动后移到首帧，见
  //    post_frame_init.dart 的 startSync）。
  final sync = await buildSyncStack(
    catalog: catalog,
    library: library,
    playback: playback,
    dataSaver: local.dataSaver,
  );
  _markStartup('同步栈', startup);
  // ⑪ 应用内更新（纯构造；包信息 / 偏好 / 平台信息读取后移到首帧）。
  final update = buildUpdateStack(quitApp: desktop.quitApp);
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
  // （托盘落地 + 更新准备/自动检查 + 同步启动 + 音源初始化）。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    revealFallback.cancel();
    _markStartup('首帧', startup);
    unawaited(WindowChrome.show());
    initAfterFirstFrame(
      catalog: catalog,
      desktop: desktop,
      update: update,
      sync: sync,
    );
  });
}
