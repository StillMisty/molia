/// 平台装配：在任何业务栈之前完成进程级一次性设置。
///
/// 只做「不依赖业务子系统」的事：图片缓存预算、日志 / 诊断、帧统计、内存
/// 守卫、窗口与字体、单实例、桌面窗口 chrome、桌面音频后端与播放功耗策略。
/// 顺序敏感点见各段注释（尤其是图片预算必须先于 `AppMemoryManager.instance`）。
library;

import 'dart:async';
import 'dart:io' show exit;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/widgets.dart';

import '../../playback/desktop_audio_init.dart';
import '../../playback/playback_power_policy.dart';
import '../../services/app_logging.dart';
import '../../services/memory/app_memory_manager.dart';
import '../../services/notification_service.dart';
import '../../services/system_fonts_service.dart';
import '../../services/window/single_instance.dart';
import '../../services/window/window_chrome.dart';
import '../../services/window/window_settings.dart';
import '../app_shell.dart' show appRootKey;
import '../perf/frame_stats.dart';
import 'app_dependencies.dart';
import 'diagnostics_stack.dart';
import 'startup_trace.dart';
import 'wiring/memory_wiring.dart';

/// 完成平台级装配并返回后续阶段需要的进程级句柄。
Future<PlatformBootstrap> bootstrapPlatform() async {
  final startup = Stopwatch()..start();

  // 图片缓存预算：显式收敛到 64 MiB（Flutter 默认 100 MiB 对移动端过大；
  // 桌面托盘 / 移动端后台还会临时压到 16 MiB）。必须在
  // `AppMemoryManager.instance` 首次访问之前设置：守卫构造时捕获这个值
  // 作为恢复上限。所有平台统一口径，避免各平台恢复出不同预算。
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      kFullImageCacheLimitBytes;

  // 日志装配（package:logging 的 handler / level 只在这里和测试配置里设一次）
  initAppLogging();
  // 诊断核心（失败缓冲 + 轮转文件日志）：构造无 I/O；文件 sink 在首次写入时
  // 才解析应用数据目录，启动不等待磁盘。历史恢复与会话前台标记立刻起跑：
  // 必须在 catalog / playback 可能产生失败之前完成，且不能阻塞启动。
  final diagnostics = buildDiagnosticsStack();
  unawaited(diagnostics.service.initialize());

  // 帧统计：默认编译期关闭；`MOLIA_PERF_TRACE=true` 时才注册回调。
  FrameStats.instance.install();

  // 托盘期内存守卫：窗口隐藏 / 最小化 / 恢复时清理或恢复图片缓存预算
  // （`molia.memory` 日志是托盘内存回归的观测点）。
  AppMemoryManager.instance.attach();
  // 系统低内存：只释放可重建的浏览 / 搜索 / 目录缓存（见 onMemoryPressure）。
  installMemoryPressureObserver();

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
  markStartupStep('窗口就绪', startup);

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

  return (
    startup: startup,
    diagnostics: diagnostics,
    revealFallback: revealFallback,
    powerPolicy: powerPolicy,
    mobilePowerPolicy: mobilePowerPolicy,
    notifications: notifications,
  );
}
