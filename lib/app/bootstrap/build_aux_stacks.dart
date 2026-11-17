/// 尾部栈：观察者收尾 → 同步 → 内存清单 → 更新 → 诊断导出 → 生命周期。
///
/// 顺序不变量与拆分前一致：热键 attach 在首帧前等完，统计 / 听歌同步接线
/// 早于同步栈（同步会读统计导出）；内存释放清单在同步栈之后（要拿 engine）；
/// 更新栈拿桌面 `quitApp`；导出器最后读设置 / 渠道 / 数据库 / 更新信息。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../data/diagnostics/database_counts.dart';
import '../../data/diagnostics/settings_snapshot.dart';
import '../../data/diagnostics/source_snapshot.dart';
import '../../providers/sync_ui_state.dart';
import '../../services/diagnostics/app_info.dart';
import '../../services/diagnostics/diagnostics_export.dart';
import 'app_dependencies.dart';
import 'startup_trace.dart';
import 'sync_stack.dart';
import 'update_stack.dart';
import 'wiring/lifecycle_wiring.dart';
import 'wiring/memory_wiring.dart';
import 'wiring/observers_wiring.dart';
import 'wiring/tray_wiring.dart';

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

/// 装配 runApp 前的尾部子系统与接线。
Future<AuxStacks> buildAuxStacks({
  required PlatformBootstrap platform,
  required CoreStacks core,
  required FeatureStacks features,
}) async {
  final catalog = core.catalog;
  final local = core.local;
  final library = core.library;
  final playback = core.playback;

  // 热键注册与前面的装配并行；runApp 前确保就绪（含冷启动恢复态）。
  await core.hotkeysFuture;
  // ⑨ 听歌统计与听歌同步接线（纯观察者：快照 + 进度 tick）。
  wirePlaybackObservers(
    playback: playback,
    library: library,
    scrobble: core.scrobble,
  );
  // ⑩ 跨设备同步（可选子系统；引擎 init / 调度器启动后移到首帧，见
  //    post_frame_init.dart 的 startSync）。
  final sync = await buildSyncStack(
    catalog: catalog,
    library: library,
    playback: playback,
    ai: features.ai,
    dataSaver: local.dataSaver,
    customCovers: local.customCovers,
    // 配对发现只在前台应答：生命周期判定留在组合根，数据层不碰 WidgetsBinding。
    isForeground: () =>
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
  );
  markStartupStep('同步栈', platform.startup);
  // 托盘期 / 系统低内存时释放可重建的业务缓存（不动收藏、历史、脚本与当前
  // 播放队列），并把「现场」先落盘（见 memory_wiring）。
  wireMemoryReclaim(
    catalog: catalog,
    local: local,
    library: library,
    playback: playback,
    sync: sync,
    libraryProvider: core.libraryProvider,
    searchProvider: core.searchProvider,
  );
  // ⑪ 应用内更新（纯构造；包信息 / 偏好 / 平台信息读取后移到首帧）。
  final update = buildUpdateStack(quitApp: features.desktop.quitApp);
  markStartupStep('更新栈（装配完成）', platform.startup);

  // 诊断导出器：设置 / 渠道 / 数据库 / 更新信息由注入的 gatherer 读取；
  // 日志读取、脱敏与组装在后台 isolate 完成。未打开诊断页时不执行。
  final diagnosticsExporter = DiagnosticsExporter(
    service: platform.diagnostics.service,
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
    logDirectory: platform.diagnostics.logSink.directory,
  );

  // 生命周期扇出与托盘存在态：先建协调者与前后台回调，再挂托盘监听
  // （不可见时补防抖写 + trim），最后接原生 AppLifecycleListener。
  final lifecycle = buildLifecycleWiring(
    local: local,
    library: library,
    playback: playback,
    sync: sync,
    update: update,
    display: features.display,
    powerPolicy: platform.powerPolicy,
    mobilePowerPolicy: platform.mobilePowerPolicy,
  );
  wireTrayPresence(
    playback: playback,
    flushDeferredWrites: lifecycle.flushDeferredWrites,
  );
  lifecycle.install(
    desktop: features.desktop,
    sourceEngineRecovery: core.sourceEngineRecovery,
    diagnostics: platform.diagnostics,
  );

  return (
    sync: sync,
    update: update,
    diagnosticsExporter: diagnosticsExporter,
    lifecycle: lifecycle,
  );
}
