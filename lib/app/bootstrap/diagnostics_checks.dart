/// 诊断检查的组合根：把 catalog / 同步 / 更新 / 数据库等已装配子系统投影成
/// 五域检查列表，并挂到统一执行器上。
///
/// 只有组合根可以同时 import providers 与 services；`services/diagnostics` 的
/// 检查实现只接收注入的端口 / 快照，不反向依赖 provider 或 UI。渠道检查直接
/// 复用 `buildCoreStacks` 已 attach 的 [SourceHealthChecker]，不另建探针。
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;

import '../../data/diagnostics/database_integrity.dart';
import '../../data/molia_database.dart';
import '../../providers/sync_ui_state.dart';
import '../../providers/sync_provider.dart';
import '../../services/diagnostics/diagnostics_bundle.dart';
import '../../services/diagnostics/diagnostics_runner.dart';
import '../../services/diagnostics/diagnostics_service.dart';
import '../../services/diagnostics/system_checks.dart';
import '../../services/notification_permission.dart';
import 'catalog_stack.dart';

/// 默认单项超时：覆盖 [kDefaultSourceCheckBudget] 的最坏情况（20 渠道 ×
/// 搜索 / 取链 / 流 + 渠道间隔），给本地检查留同一上限也不会误伤——本地
/// 检查各自有更短的内部分预算。
const Duration kDiagnosticsCheckTimeout = Duration(minutes: 7);

/// 组装统一检查列表并返回执行器。
///
/// [loadAppInfo] 与导出器共用同一个 gatherer（读取失败回退 unknown，不阻塞
/// 启动）；[database] 仅测试注入，生产使用 [MoliaDatabase.instance]。
DiagnosticsRunner buildDiagnosticsRunner({
  required DiagnosticsService service,
  required CatalogStack catalog,
  required SyncProvider syncProvider,
  required Future<DiagnosticsAppInfo> Function() loadAppInfo,
  required bool desktopAudioAvailable,
  bool? isDesktop,
  MoliaDatabase? database,
}) {
  final db = database ?? MoliaDatabase.instance;
  final desktop =
      isDesktop ??
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);
  final sourceHealth = service.health;

  final checks = <DiagnosticCheck>[
    AppVersionCheck(load: loadAppInfo),
    SessionExitCheck(read: () => service.sessionInfo),
    NotificationPermissionCheck(status: NotificationPermission.status),
    AudioBackendCheck(
      available: () => desktopAudioAvailable,
      isDesktop: () => desktop,
    ),
    SourceEngineCheck(
      engineReady: () => catalog.sourceManager.engineReady,
      engineFailed: () => catalog.sourceManager.engineFailed,
      activeScriptName: () => catalog.sourceManager.activeScript?.name,
    ),
    if (sourceHealth != null) SourceHealthCheck(checker: sourceHealth),
    LogWriteCheck(status: () => service.logStatus),
    DatabaseSchemaCheck(
      expectedVersion: db.schemaVersion,
      readVersion: () => readMoliaSchemaVersion(db),
    ),
    DatabaseIntegrityCheck(quickCheck: () => moliaDatabaseQuickCheck(db)),
    SyncTransportCheck(snapshot: () => mapSyncUiState(syncProvider.state)),
    BiliAccountCheck(
      read: () => (
        loggedIn: catalog.biliAccount.isLoggedIn,
        expired: catalog.biliAccount.sessionExpired,
      ),
    ),
  ];

  return DiagnosticsRunner(
    checks: checks,
    config: const DiagnosticRunnerConfig(
      checkTimeout: kDiagnosticsCheckTimeout,
    ),
  );
}

/// `SyncUiState` → 诊断快照：只保留传输名、开关与不可用原因码，不抄 host /
/// token / 口令。
DiagnosticsSyncSnapshot mapSyncUiState(SyncUiState state) {
  return DiagnosticsSyncSnapshot(
    enabled: state.enabled,
    transports: [
      for (final transport in state.transports.values)
        DiagnosticsSyncTransportSnapshot(
          name: transport.id.name,
          configured: transport.configured,
          enabled: transport.enabled,
          running: transport.running,
          unavailableReason: transport.unavailableReason,
        ),
    ],
  );
}
