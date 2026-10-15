import 'dart:async';

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
import 'services/window/window_chrome.dart';

/// 唯一 composition root：只做「平台装配 + 按顺序调用各 stack builder +
/// runApp + 首帧回调」，子系统内部接线见 `lib/app/bootstrap/**`。
///
/// 拆成 stack builders 后不再有 `late` / 可变槽位 / 前向引用：
/// - 服务 ↔ 后端互为依赖 → 取链是共享解析函数（`local_playback_chain.dart`）；
/// - 歌词服务 ↔ 下载服务互为依赖 → 歌词服务先建、离线歌词读取收在存储级
///   函数里（`local_data_stack.dart`）；
/// - 系统媒体会话 ↔ provider → handler 在 provider 就绪后装配
///   （`playback_stack.dart` 的 `mediaSessionFactory`）；
/// - SyncEngine ↔ 局域网传输 → 快照提供者在同一个 builder 内接线
///   （`sync_stack.dart`）。
///
/// 初始化顺序与副作用时机与拆分前一致（`unawaited` 的启动维护、各模块
/// `init()` 的 await、runApp 前的启动预解析、首帧回调）；唯一的顺序调整是
/// 系统媒体会话从「下载/资料库初始化之前」移到「provider 建好之后」
/// （恢复态切歌键要直接落到 provider，见 `playback_stack.dart`），
/// 仍在 runApp 之前。
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
  // 资料库 provider（收藏/历史/列表）：AI 推歌、托盘、Provider 树共用。
  final libraryProvider = LibraryProvider(
    repository: library.libraryRepository,
    playbackProvider: playback.playbackProvider,
  );
  // ⑤ 桌面壳（托盘偏好 + 统一退出路径 + 关闭策略 + 菜单状态同步）。
  final desktop = await buildDesktopStack(
    playback: playback.playbackProvider,
    libraryProvider: libraryProvider,
    playStatisticsService: library.playStatisticsService,
  );
  // ⑥ AI 推歌（默认关闭，配置走安全存储）。
  final ai = buildAiStack(
    catalog: catalog,
    library: library,
    playback: playback.playbackProvider,
    libraryProvider: libraryProvider,
  );
  // ⑦ 歌词会话（与播放页共享 LyricsService）。
  final lyrics = buildLyricsStack(local: local);
  // ⑧ 歌词显示与主题（含 runApp 前的启动预解析：首帧即封面色）。
  final display = await buildLyricsDisplayStack(
    catalog: catalog,
    playback: playback.playbackProvider,
    lyricsProvider: lyrics.lyricsProvider,
    audioHandler: playback.audioHandler,
  );
  // ⑨ 听歌统计接线（纯观察者：快照 + 进度 tick）。
  wirePlayStatistics(
    playback: playback.playbackProvider,
    service: library.playStatisticsService,
  );
  // ⑩ 跨设备同步（可选子系统；初始化失败不阻断启动）。
  final sync = await buildSyncStack(
    catalog: catalog,
    library: library,
    playback: playback.playbackProvider,
  );
  // ⑪ 应用内更新（渠道 / 自动检查 / 下载安装；退出走统一路径）。
  final update = await buildUpdateStack(quitApp: desktop.quitApp);

  // 前台恢复：补一轮同步；并复查更新安装权限——从「安装未知应用」系统
  // 授权页返回后要把按钮从「去授权」切回「立即安装」。
  AppLifecycleListener(
    onResume: () {
      sync.provider.scheduleSync(delay: const Duration(seconds: 3));
      unawaited(update.provider.handleAppResumed());
    },
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
      child: const MyThemedApp(),
    ),
  );

  // 首帧后：托盘落地 + 自动更新检查 + 音源初始化（随后首轮同步）。
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => initAfterFirstFrame(
      catalog: catalog,
      desktop: desktop,
      update: update,
      syncProvider: sync.provider,
    ),
  );
}
