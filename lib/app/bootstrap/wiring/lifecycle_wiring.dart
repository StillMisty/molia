/// 应用生命周期扇出：系统事件只在这里转给各子系统。
///
/// [AppLifecycleCoordinator] 是唯一 owner，避免组合根与 app_shell 各持一份
/// `WidgetsBindingObserver`；前后台回调同时驱动移动端播放功耗与图片缓存，
/// 桌面托盘则另走 `tray_wiring.dart` 的 `AppPresence`。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../playback/playback_power_policy.dart';
import '../../../services/memory/app_memory_manager.dart';
import '../../app_lifecycle_coordinator.dart';
import '../desktop_stack.dart';
import '../diagnostics_stack.dart';
import '../library_stack.dart';
import '../local_data_stack.dart';
import '../lyrics_display_stack.dart';
import '../playback_stack.dart';
import '../source_engine_recovery.dart';
import '../sync_stack.dart';
import '../update_stack.dart';

/// 生命周期扇出 + 前后台回调；[install] 之后系统事件才会进入。
class LifecycleWiring {
  LifecycleWiring._({
    required this.coordinator,
    required this.powerPolicy,
    required this.mobilePowerPolicy,
    required this.display,
  });

  final AppLifecycleCoordinator coordinator;
  final PlaybackPowerPolicy powerPolicy;
  final bool mobilePowerPolicy;
  final LyricsDisplayStack display;

  /// 连续滑杆 / 封面 seed 用的是防抖写：窗口不可见或退后台前补一次，
  /// 避免用户拖完就关窗口时丢掉最后一段（派生缓存丢得起，设置 JSON 不该丢）。
  void flushDeferredWrites() {
    unawaited(display.lyricsDisplaySettings.flushPersistence());
    unawaited(display.artworkPaletteService.flushSeedCache());
  }

  /// 移动端前后台同时喂 `PlaybackPowerPolicy`（桌面不接：托盘 / 最小化另有
  /// `AppPresence`，且桌面播放保持前台节拍）；`onPause` / `onHide` 都先走
  /// 同一套「收后台工作」，只有 paused 额外触发会话提交 / 统计落盘。
  void onAppBackground({bool paused = false}) {
    flushDeferredWrites();
    if (mobilePowerPolicy) {
      powerPolicy.markBackground();
      // 移动端 30s 后回收图片缓存；快速切回时 onAppForeground 会取消。
      // 桌面托盘走 AppPresence，生命周期不触发这里。
      AppMemoryManager.instance.onAppBackground();
    }
    unawaited(coordinator.hidden());
    if (paused) unawaited(coordinator.paused());
  }

  /// 接上原生生命周期（放在托盘存在态监听之后，与拆分前顺序一致）。
  void install({
    required DesktopStack desktop,
    required SourceEngineNetworkRecovery sourceEngineRecovery,
    required DiagnosticsStack diagnostics,
  }) {
    AppLifecycleListener(
      // macOS Cmd+Q / Linux 应用级 quit 与托盘「退出」走同一条落盘路径：
      // 空闲时先取消系统终止、启动 quitApp；进入销毁阶段后放行原生终止。
      onExitRequested: () async => desktop.handleExitRequest(),
      onResume: () {
        if (mobilePowerPolicy) {
          powerPolicy.markForeground();
          AppMemoryManager.instance.onAppForeground();
        }
        unawaited(coordinator.resumed());
      },
      onPause: () => onAppBackground(paused: true),
      onHide: onAppBackground,
      // 进程销毁：关掉文件日志（有界刷盘）+ 取消音源引擎的网络恢复订阅，
      // 不影响系统回收速度。
      onDetach: () {
        unawaited(sourceEngineRecovery.dispose());
        unawaited(diagnostics.service.dispose());
      },
    );
  }
}

/// 建生命周期协调者并注册各子系统的前后台反应。
///
/// 注册顺序与拆分前一致：同步 → 更新 → 省流网络刷新 → 播放会话 / 统计落盘。
LifecycleWiring buildLifecycleWiring({
  required LocalDataStack local,
  required LibraryStack library,
  required PlaybackStack playback,
  required SyncStack sync,
  required UpdateStack update,
  required LyricsDisplayStack display,
  required PlaybackPowerPolicy powerPolicy,
  required bool mobilePowerPolicy,
}) {
  final appLifecycle = AppLifecycleCoordinator()
    ..register(
      AppLifecycleParticipant(
        onResumed: sync.provider.onAppResumed,
        onHidden: sync.provider.onAppHidden,
      ),
    )
    ..register(
      AppLifecycleParticipant(
        onResumed: () async {
          await update.provider.handleAppResumed();
          await update.coordinator.handleAppResumed();
        },
      ),
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

  return LifecycleWiring._(
    coordinator: appLifecycle,
    powerPolicy: powerPolicy,
    mobilePowerPolicy: mobilePowerPolicy,
    display: display,
  );
}
