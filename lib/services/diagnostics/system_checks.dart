/// 统一检查项实现：应用 / 音源 / 播放后端 / 存储 / 账号与同步五域。
///
/// 检查只读注入的状态或端口，不直接读 UI / 播放实现；所有失败在写结果前
/// 归一为 [HealthFailure]，原始异常、URL、响应正文与 Cookie 不进入
/// [DiagnosticCheckResult]。渠道检查复用 [SourceHealthChecker] 的顺序、
/// 冷却与取消语义，只负责把结果逐条投影进统一执行器。
library;

import 'dart:async';

import '../../domain/models/diagnostics.dart';
import '../../domain/models/failure.dart';
import '../../domain/ports/sync_transport.dart' show SyncUnavailableReason;
import '../notification_permission.dart';
import 'diagnostics_bundle.dart' show DiagnosticsAppInfo;
import 'diagnostics_runner.dart';
import 'source_health_check_adapter.dart';
import 'source_health_checker.dart';

/// 渠道检查的默认总预算：20 渠道 ×（搜索 8s + 取链 5s + 流 5s）+ 渠道间隔，
/// 留一点余量给调度。组合根据此配置 runner 的单项超时，避免整组被默认
/// 10s 截断。测试可注入更短预算。
const Duration kDefaultSourceCheckBudget = Duration(minutes: 6, seconds: 30);

/// 一次检查要观察的应用信息（版本号只作为稳定短值展示）。
class AppVersionCheck implements DiagnosticCheck {
  AppVersionCheck({required this.load});

  final Future<DiagnosticsAppInfo> Function() load;

  @override
  DiagnosticCheckId get key => DiagnosticCheckId.appVersion;

  @override
  DiagnosticCheckGroup get group => DiagnosticCheckGroup.app;

  @override
  bool get requiresNetwork => false;

  @override
  Future<void> run(DiagnosticCheckContext context) async {
    final info = await load();
    final version = info.version.trim();
    context.addResult(
      DiagnosticCheckResult(
        id: key,
        group: group,
        status: DiagnosticCheckStatus.ok,
        at: context.now(),
        stableValue: version.isEmpty ? 'unknown' : version,
      ),
    );
  }
}

/// 上次退出是否异常：上次停在「前台」才提示，后台回收不算异常。
class SessionExitCheck implements DiagnosticCheck {
  SessionExitCheck({required this.read});

  final DiagnosticSessionInfo? Function() read;

  @override
  DiagnosticCheckId get key => DiagnosticCheckId.sessionExit;

  @override
  DiagnosticCheckGroup get group => DiagnosticCheckGroup.app;

  @override
  bool get requiresNetwork => false;

  @override
  Future<void> run(DiagnosticCheckContext context) async {
    final info = read();
    if (info == null) {
      context.addResult(
        DiagnosticCheckResult(
          id: key,
          group: group,
          status: DiagnosticCheckStatus.skipped,
          at: context.now(),
          stableValue: 'unknown',
        ),
      );
      return;
    }
    final abnormal = info.previousAbnormalExit;
    context.addResult(
      DiagnosticCheckResult(
        id: key,
        group: group,
        status: abnormal
            ? DiagnosticCheckStatus.warning
            : DiagnosticCheckStatus.ok,
        at: context.now(),
        failure: abnormal
            ? const HealthFailure(kind: FailureKind.unknown)
            : null,
        stableValue: abnormal ? 'abnormal' : 'clean',
      ),
    );
  }
}

/// 通知权限：拒绝只影响提醒，不算应用故障。
class NotificationPermissionCheck implements DiagnosticCheck {
  NotificationPermissionCheck({required this.status});

  final Future<NotificationPermissionStatus> Function() status;

  @override
  DiagnosticCheckId get key => DiagnosticCheckId.notificationPermission;

  @override
  DiagnosticCheckGroup get group => DiagnosticCheckGroup.app;

  @override
  bool get requiresNetwork => false;

  @override
  Future<void> run(DiagnosticCheckContext context) async {
    final result = await status();
    final (
      DiagnosticCheckStatus checkStatus,
      HealthFailure? failure,
    ) = switch (result) {
      NotificationPermissionStatus.granted => (DiagnosticCheckStatus.ok, null),
      NotificationPermissionStatus.unsupported => (
        DiagnosticCheckStatus.skipped,
        null,
      ),
      NotificationPermissionStatus.denied ||
      NotificationPermissionStatus.permanentlyDenied => (
        DiagnosticCheckStatus.warning,
        const HealthFailure(kind: FailureKind.unauthorized),
      ),
    };
    context.addResult(
      DiagnosticCheckResult(
        id: key,
        group: group,
        status: checkStatus,
        at: context.now(),
        failure: failure,
        stableValue: result.name,
      ),
    );
  }
}

/// 桌面播放后端：只报「系统缺少音频组件」类型化结论，不暴露初始化原文。
class AudioBackendCheck implements DiagnosticCheck {
  AudioBackendCheck({required this.available, required this.isDesktop});

  final bool Function() available;
  final bool Function() isDesktop;

  @override
  DiagnosticCheckId get key => DiagnosticCheckId.audioBackend;

  @override
  DiagnosticCheckGroup get group => DiagnosticCheckGroup.playback;

  @override
  bool get requiresNetwork => false;

  @override
  Future<void> run(DiagnosticCheckContext context) async {
    if (!isDesktop()) {
      context.addResult(
        DiagnosticCheckResult(
          id: key,
          group: group,
          status: DiagnosticCheckStatus.skipped,
          at: context.now(),
          stableValue: 'not_desktop',
        ),
      );
      return;
    }
    final backendAvailable = available();
    context.addResult(
      DiagnosticCheckResult(
        id: key,
        group: group,
        status: backendAvailable
            ? DiagnosticCheckStatus.ok
            : DiagnosticCheckStatus.failed,
        at: context.now(),
        failure: backendAvailable
            ? null
            : const HealthFailure(kind: FailureKind.unsupported),
        stableValue: backendAvailable ? 'available' : 'unavailable',
      ),
    );
  }
}

/// LX 音源引擎：只有脚本名进入稳定值，脚本错误只给类型化类别。
class SourceEngineCheck implements DiagnosticCheck {
  SourceEngineCheck({
    required this.engineReady,
    required this.engineFailed,
    required this.activeScriptName,
  });

  final bool Function() engineReady;
  final bool Function() engineFailed;
  final String? Function() activeScriptName;

  @override
  DiagnosticCheckId get key => DiagnosticCheckId.sourceEngine;

  @override
  DiagnosticCheckGroup get group => DiagnosticCheckGroup.sources;

  @override
  bool get requiresNetwork => false;

  @override
  Future<void> run(DiagnosticCheckContext context) async {
    final scriptName = activeScriptName();
    if (engineFailed()) {
      context.addResult(
        DiagnosticCheckResult(
          id: key,
          group: group,
          status: DiagnosticCheckStatus.failed,
          at: context.now(),
          failure: const HealthFailure(
            kind: FailureKind.scriptError,
            retryable: true,
          ),
          stableValue: scriptName,
        ),
      );
      return;
    }
    if (engineReady()) {
      context.addResult(
        DiagnosticCheckResult(
          id: key,
          group: group,
          status: DiagnosticCheckStatus.ok,
          at: context.now(),
          stableValue: scriptName,
        ),
      );
      return;
    }
    if (scriptName == null) {
      // 没有激活脚本时内置平台照常工作，引擎未运行不是故障。
      context.addResult(
        DiagnosticCheckResult(
          id: key,
          group: group,
          status: DiagnosticCheckStatus.skipped,
          at: context.now(),
          stableValue: 'no_script',
        ),
      );
      return;
    }
    context.addResult(
      DiagnosticCheckResult(
        id: key,
        group: group,
        status: DiagnosticCheckStatus.warning,
        at: context.now(),
        failure: const HealthFailure(
          kind: FailureKind.engineRestarting,
          retryable: true,
        ),
        stableValue: scriptName,
      ),
    );
  }
}

/// 渠道检查：启动（或加入）一轮 [SourceHealthChecker] 运行，按渠道逐条写入
/// 搜索 / 取链 / 首字节结果。
///
/// 不复制检查器的顺序、冷却与取消：执行器取消时直接 `checker.cancel()`，
/// 已写入的结果保留（runner 不会因整组超时清掉它们）。页面打开不会自动
/// 触发，只有用户点「开始检查」时 runner 才会调用这里。
class SourceHealthCheck implements DiagnosticCheck {
  SourceHealthCheck({
    required this.checker,
    this.totalBudget = kDefaultSourceCheckBudget,
    this.pollInterval = const Duration(milliseconds: 200),
  });

  final SourceHealthChecker checker;
  final Duration totalBudget;

  /// runner 取消没有回调，只能低频轮询 `context.isCancelled`；仅在检查运行
  /// 期间存在，不产生常驻定时器。
  final Duration pollInterval;

  DateTime? _activeRunStartedAt;
  int _projected = 0;
  Completer<void>? _pendingWake;

  @override
  DiagnosticCheckId get key => DiagnosticCheckId.channelSearch;

  @override
  DiagnosticCheckGroup get group => DiagnosticCheckGroup.sources;

  @override
  bool get requiresNetwork => true;

  @override
  Future<void> run(DiagnosticCheckContext context) async {
    if (checker.targetCount == 0) {
      context.addResult(
        DiagnosticCheckResult(
          id: key,
          group: group,
          status: DiagnosticCheckStatus.skipped,
          at: context.now(),
          stableValue: 'no_channels',
        ),
      );
      return;
    }
    if (!checker.canStart && !checker.running) {
      // 冷却中：尊重检查器自己的节流，不在这里复制或绕过冷却逻辑。
      context.addResult(
        DiagnosticCheckResult(
          id: key,
          group: group,
          status: DiagnosticCheckStatus.skipped,
          at: context.now(),
          stableValue: 'cooldown',
        ),
      );
      return;
    }

    final subscription = checker.changes.listen((_) {
      _pendingWake?.complete();
      _drain(context);
    });
    try {
      if (checker.canStart) await checker.start();
      final deadline = DateTime.now().add(totalBudget);
      while (true) {
        _drain(context);
        if (context.isCancelled) {
          checker.cancel();
          return;
        }
        if (!checker.running) break;
        if (DateTime.now().isAfter(deadline)) {
          checker.cancel();
          _drain(context);
          context.addResult(
            DiagnosticCheckResult(
              id: key,
              group: group,
              status: DiagnosticCheckStatus.failed,
              at: context.now(),
              failure: const HealthFailure(
                kind: FailureKind.timeout,
                retryable: true,
              ),
              stableValue: 'timeout',
            ),
          );
          return;
        }
        await _waitForChange();
      }
      _drain(context);
    } finally {
      _pendingWake = null;
      await subscription.cancel();
    }
  }

  Future<void> _waitForChange() {
    final wake = Completer<void>();
    _pendingWake = wake;
    return Future.any<void>([wake.future, Future<void>.delayed(pollInterval)])
        .whenComplete(() {
          if (identical(_pendingWake, wake)) _pendingWake = null;
        });
  }

  /// 只追加尚未投影的渠道结果；新运行（不同开始时间）从头计。
  void _drain(DiagnosticCheckContext context) {
    final run = checker.current ?? checker.runs.firstOrNull;
    if (run == null) return;
    if (_activeRunStartedAt != run.startedAt) {
      _activeRunStartedAt = run.startedAt;
      _projected = 0;
    }
    final results = run.results;
    for (var index = _projected; index < results.length; index++) {
      if (context.isCancelled) return;
      for (final result in healthChannelCheckResults(
        results[index],
        at: context.now(),
      )) {
        context.addResult(result);
      }
    }
    _projected = results.length;
  }
}

/// 本地日志落盘：不可用算失败，已停止只算提示。
class LogWriteCheck implements DiagnosticCheck {
  LogWriteCheck({required this.status});

  final DiagnosticLogStatus Function() status;

  @override
  DiagnosticCheckId get key => DiagnosticCheckId.logWrite;

  @override
  DiagnosticCheckGroup get group => DiagnosticCheckGroup.storage;

  @override
  bool get requiresNetwork => false;

  @override
  Future<void> run(DiagnosticCheckContext context) async {
    final current = status();
    final (
      DiagnosticCheckStatus checkStatus,
      HealthFailure? failure,
    ) = switch (current) {
      DiagnosticLogStatus.recording => (DiagnosticCheckStatus.ok, null),
      DiagnosticLogStatus.stopped => (
        DiagnosticCheckStatus.warning,
        const HealthFailure(kind: FailureKind.unknown, retryable: true),
      ),
      DiagnosticLogStatus.unavailable => (
        DiagnosticCheckStatus.failed,
        const HealthFailure(kind: FailureKind.unknown, retryable: true),
      ),
    };
    context.addResult(
      DiagnosticCheckResult(
        id: key,
        group: group,
        status: checkStatus,
        at: context.now(),
        failure: failure,
        stableValue: current.name,
      ),
    );
  }
}

/// 数据库 schema 版本与当前应用预期比较。
class DatabaseSchemaCheck implements DiagnosticCheck {
  DatabaseSchemaCheck({
    required this.expectedVersion,
    required this.readVersion,
  });

  final int expectedVersion;
  final Future<int?> Function() readVersion;

  @override
  DiagnosticCheckId get key => DiagnosticCheckId.databaseSchema;

  @override
  DiagnosticCheckGroup get group => DiagnosticCheckGroup.storage;

  @override
  bool get requiresNetwork => false;

  @override
  Future<void> run(DiagnosticCheckContext context) async {
    final actual = await readVersion();
    if (actual == null) {
      context.addResult(
        DiagnosticCheckResult(
          id: key,
          group: group,
          status: DiagnosticCheckStatus.warning,
          at: context.now(),
          failure: const HealthFailure(kind: FailureKind.unknown),
          stableValue: 'unreadable',
        ),
      );
      return;
    }
    if (actual == expectedVersion) {
      context.addResult(
        DiagnosticCheckResult(
          id: key,
          group: group,
          status: DiagnosticCheckStatus.ok,
          at: context.now(),
          stableValue: '$actual',
        ),
      );
      return;
    }
    // 库比应用新意味着降级风险，比旧库缺失迁移更值得报失败。
    final newer = actual > expectedVersion;
    context.addResult(
      DiagnosticCheckResult(
        id: key,
        group: group,
        status: newer
            ? DiagnosticCheckStatus.failed
            : DiagnosticCheckStatus.warning,
        at: context.now(),
        failure: const HealthFailure(kind: FailureKind.unknown),
        stableValue: '$actual/$expectedVersion',
      ),
    );
  }
}

/// 数据库完整性：`PRAGMA quick_check`，内部 3s 预算；稳定值只写 ok/corrupt。
class DatabaseIntegrityCheck implements DiagnosticCheck {
  DatabaseIntegrityCheck({
    required this.quickCheck,
    this.timeout = const Duration(seconds: 3),
  });

  final Future<bool> Function() quickCheck;
  final Duration timeout;

  @override
  DiagnosticCheckId get key => DiagnosticCheckId.databaseIntegrity;

  @override
  DiagnosticCheckGroup get group => DiagnosticCheckGroup.storage;

  @override
  bool get requiresNetwork => false;

  @override
  Future<void> run(DiagnosticCheckContext context) async {
    var healthy = false;
    try {
      healthy = await quickCheck().timeout(timeout);
    } catch (_) {
      // 打不开 / 超时 / 探测抛错都按损坏处理；原始异常不进入结果。
      healthy = false;
    }
    context.addResult(
      DiagnosticCheckResult(
        id: key,
        group: group,
        status: healthy
            ? DiagnosticCheckStatus.ok
            : DiagnosticCheckStatus.failed,
        at: context.now(),
        failure: healthy
            ? null
            : const HealthFailure(kind: FailureKind.unknown),
        stableValue: healthy ? 'ok' : 'corrupt',
      ),
    );
  }
}

/// 单路同步传输的只读事实（组合根从 `SyncUiState` 投影；不含主机 / 口令）。
class DiagnosticsSyncTransportSnapshot {
  const DiagnosticsSyncTransportSnapshot({
    required this.name,
    required this.configured,
    required this.enabled,
    required this.running,
    this.unavailableReason,
  });

  final String name;
  final bool configured;
  final bool enabled;
  final bool running;
  final String? unavailableReason;
}

/// 同步状态快照（组合根投影，服务层不 import provider）。
class DiagnosticsSyncSnapshot {
  const DiagnosticsSyncSnapshot({
    required this.enabled,
    required this.transports,
  });

  final bool enabled;
  final List<DiagnosticsSyncTransportSnapshot> transports;
}

/// 同步传输健康：未启用跳过；启用但不可用 / 未运行分别报失败 / 警告。
class SyncTransportCheck implements DiagnosticCheck {
  SyncTransportCheck({required this.snapshot});

  final DiagnosticsSyncSnapshot? Function() snapshot;

  @override
  DiagnosticCheckId get key => DiagnosticCheckId.syncTransport;

  @override
  DiagnosticCheckGroup get group => DiagnosticCheckGroup.sync;

  @override
  bool get requiresNetwork => false;

  @override
  Future<void> run(DiagnosticCheckContext context) async {
    final state = snapshot();
    if (state == null) {
      context.addResult(
        DiagnosticCheckResult(
          id: key,
          group: group,
          status: DiagnosticCheckStatus.skipped,
          at: context.now(),
          stableValue: 'unknown',
        ),
      );
      return;
    }
    if (!state.enabled) {
      context.addResult(
        DiagnosticCheckResult(
          id: key,
          group: group,
          status: DiagnosticCheckStatus.skipped,
          at: context.now(),
          stableValue: 'off',
        ),
      );
      return;
    }
    final active = state.transports
        .where((transport) => transport.enabled)
        .toList(growable: false);
    if (active.isEmpty) {
      context.addResult(
        DiagnosticCheckResult(
          id: key,
          group: group,
          status: DiagnosticCheckStatus.warning,
          at: context.now(),
          failure: const HealthFailure(kind: FailureKind.unknown),
          stableValue: 'none',
        ),
      );
      return;
    }

    var worst = DiagnosticCheckStatus.ok;
    HealthFailure? failure;
    for (final transport in active) {
      final reason = transport.unavailableReason;
      if (reason == SyncUnavailableReason.permissionDenied) {
        worst = DiagnosticCheckStatus.failed;
        failure = const HealthFailure(
          kind: FailureKind.unauthorized,
          retryable: true,
        );
        continue;
      }
      if (reason != null) {
        worst = DiagnosticCheckStatus.failed;
        failure ??= const HealthFailure(kind: FailureKind.unknown);
        continue;
      }
      if (!transport.running) {
        if (worst == DiagnosticCheckStatus.ok) {
          worst = DiagnosticCheckStatus.warning;
          failure = const HealthFailure(
            kind: FailureKind.engineRestarting,
            retryable: true,
          );
        }
        continue;
      }
      // 已配置且运行：ok。
    }

    context.addResult(
      DiagnosticCheckResult(
        id: key,
        group: group,
        status: worst,
        at: context.now(),
        failure: failure,
        stableValue: active.map(_transportLabel).join(','),
      ),
    );
  }

  String _transportLabel(DiagnosticsSyncTransportSnapshot transport) {
    final state =
        transport.unavailableReason ?? (transport.running ? 'ok' : 'stopped');
    return '${transport.name}:$state';
  }
}

/// B 站账号：只读登录 / 过期布尔，不读 Cookie 值。
class BiliAccountCheck implements DiagnosticCheck {
  BiliAccountCheck({required this.read});

  final ({bool loggedIn, bool expired}) Function() read;

  @override
  DiagnosticCheckId get key => DiagnosticCheckId.biliAccount;

  @override
  DiagnosticCheckGroup get group => DiagnosticCheckGroup.sync;

  @override
  bool get requiresNetwork => false;

  @override
  Future<void> run(DiagnosticCheckContext context) async {
    final state = read();
    if (!state.loggedIn) {
      context.addResult(
        DiagnosticCheckResult(
          id: key,
          group: group,
          status: DiagnosticCheckStatus.skipped,
          at: context.now(),
          stableValue: 'logged_out',
        ),
      );
      return;
    }
    if (state.expired) {
      context.addResult(
        DiagnosticCheckResult(
          id: key,
          group: group,
          status: DiagnosticCheckStatus.warning,
          at: context.now(),
          failure: const HealthFailure(kind: FailureKind.unauthorized),
          stableValue: 'expired',
        ),
      );
      return;
    }
    context.addResult(
      DiagnosticCheckResult(
        id: key,
        group: group,
        status: DiagnosticCheckStatus.ok,
        at: context.now(),
        stableValue: 'logged_in',
      ),
    );
  }
}
