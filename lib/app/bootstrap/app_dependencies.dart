/// 组合根各阶段的产物：只声明「谁依赖谁装好的什么」，不承担构造顺序。
///
/// 顺序与副作用全部留在阶段函数里（[bootstrapPlatform] / build_*_stacks /
/// wiring），这里只作为参数与返回值的形状，避免 main() 与阶段函数互相
/// import 形成环。
library;

import 'dart:async';

import '../../playback/playback_power_policy.dart';
import '../../providers/channel_selection.dart';
import '../../providers/library_provider.dart';
import '../../providers/search_provider.dart';
import '../../services/diagnostics/diagnostics_export.dart';
import '../../services/notification_service.dart';
import 'ai_stack.dart';
import 'catalog_stack.dart';
import 'desktop_stack.dart';
import 'diagnostics_stack.dart';
import 'library_stack.dart';
import 'local_data_stack.dart';
import 'lyrics_display_stack.dart';
import 'lyrics_stack.dart';
import 'playback_stack.dart';
import 'scrobble_stack.dart';
import 'source_engine_recovery.dart';
import 'sync_stack.dart';
import 'update_stack.dart';
import 'wiring/lifecycle_wiring.dart';

/// 平台装配产物（`platform_bootstrap.dart`）。
typedef PlatformBootstrap = ({
  /// 启动总计时（`molia.startup` 的累计阶段行共用）。
  Stopwatch startup,
  DiagnosticsStack diagnostics,

  /// 首帧显示兜底：装配异常 / 卡住时窗口也必须出现（show 幂等）。
  Timer revealFallback,
  PlaybackPowerPolicy powerPolicy,
  bool mobilePowerPolicy,
  NotificationService notifications,
});

/// 核心栈产物：目录 → 本地数据 / 资料库 → 播放 → 渠道 / 搜索 → 观察者初接线。
typedef CoreStacks = ({
  CatalogStack catalog,
  LocalDataStack local,
  LibraryStack library,
  PlaybackStack playback,
  ScrobbleStack scrobble,
  LibraryProvider libraryProvider,
  ChannelSelection channelSelection,
  SearchProvider searchProvider,
  SourceEngineNetworkRecovery sourceEngineRecovery,

  /// 全局热键注册（平台通道）已经启动；runApp 前 await 一次即可。
  Future<void> hotkeysFuture,
});

/// 功能栈产物：桌面壳 / AI 推歌 / 歌词会话 / 歌词显示与主题。
typedef FeatureStacks = ({
  DesktopStack desktop,
  AiStack ai,
  LyricsStack lyrics,
  LyricsDisplayStack display,
});

/// 尾部栈产物：同步 / 更新 / 诊断导出，以及生命周期与托盘接线后的句柄。
typedef AuxStacks = ({
  SyncStack sync,
  UpdateStack update,
  DiagnosticsExporter diagnosticsExporter,

  /// 生命周期扇出与前后台回调（`wiring/lifecycle_wiring.dart`）。
  LifecycleWiring lifecycle,
});

/// runApp 前的全部产物；[root_widget] 与首帧回调从这里取。
class AppDependencies {
  const AppDependencies({
    required this.platform,
    required this.core,
    required this.features,
    required this.aux,
  });

  final PlatformBootstrap platform;
  final CoreStacks core;
  final FeatureStacks features;
  final AuxStacks aux;
}
