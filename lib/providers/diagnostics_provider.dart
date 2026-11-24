/// 问题排查页的分区状态：把诊断服务的只读快照投影成按分区订阅的
/// [ValueListenable]，页面各卡片只重建自己关心的那一份。
///
/// provider 挂在根 Provider 树、与应用同生命周期；报告 / 日志动作分别由
/// 独立控制器承载，本类只保留 service 订阅、窄 notifier 与刷新逻辑。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/models/diagnostics.dart';
import '../services/diagnostics/diagnostics_bundle.dart';
import '../services/diagnostics/diagnostics_export.dart';
import '../services/diagnostics/diagnostics_service.dart';
import '../services/diagnostics/log_tail_reader.dart';
import '../services/diagnostics/redaction.dart';
import '../services/diagnostics/resolve_metrics.dart';
import '../services/save_as.dart';
import 'diagnostics/diagnostics_log_controller.dart';
import 'diagnostics/diagnostics_report_controller.dart';
import 'diagnostics/diagnostics_view_models.dart';
import 'snapshot_source.dart';

export 'diagnostics/diagnostics_report_controller.dart'
    show
        DiagnosticsCopyText,
        DiagnosticsShareFile,
        DiagnosticsTempFileWriter,
        buildDiagnosticsIssueUri;
export 'diagnostics/diagnostics_view_models.dart';

/// 诊断页的聚合快照：UI 经 `diagnosticsPageProvider` 读它。
///
/// 页面各卡片仍按分区订阅窄 [ValueListenable]（summary / 检查 / 日志…），
/// 这里只是把同一批值收成一份不可变快照，方便整体读取与测试断言。
@immutable
class DiagnosticsState {
  const DiagnosticsState({
    required this.summary,
    required this.checkResults,
    required this.issueGroups,
    required this.session,
    required this.appInfo,
    required this.reportState,
    required this.logsState,
    required this.metrics,
    required this.isExporting,
    required this.hasCheckableChannels,
  });

  final DiagnosticsSummary summary;
  final DiagnosticsChecksState checkResults;
  final List<DiagnosticIssueGroup> issueGroups;
  final DiagnosticSessionInfo? session;
  final DiagnosticsAppInfo? appInfo;
  final DiagnosticsReportState reportState;
  final DiagnosticsLogsState logsState;
  final ResolveMetricsSnapshot metrics;
  final bool isExporting;
  final bool hasCheckableChannels;
}

/// 页面状态与动作的唯一入口；所有通知都走窄 [ValueListenable]。
///
/// 对外形态是「不可变快照 + 控制器」（ADR-0041「启动期状态对象」）：
/// `diagnosticsPageProvider` 镜像 [DiagnosticsState]，命令 / 窄订阅经
/// `diagnosticsPageControllerProvider` 取实例；日志流 / 导出 / 健康检查不变。
class DiagnosticsProvider implements SnapshotSource<DiagnosticsState> {
  DiagnosticsProvider({
    required this.service,
    required this.builder,
    required this.saveAs,
    Future<DiagnosticsAppInfo> Function()? appInfo,
    Future<bool> Function()? restartEngine,
    LogTailReader? logReader,
    DiagnosticsCopyText? copyText,
    DiagnosticsShareFile? shareFile,
    Future<Directory> Function()? tempDirectory,
    DiagnosticsTempFileWriter? writeTempFile,
    Future<void> Function(String path)? deleteTempFile,
    this.homeDirectories,
    this.openExternal,
    DateTime Function()? now,
  }) : _appInfoLoader = appInfo,
       // ignore: prefer_initializing_formals
       _restartEngine = restartEngine {
    _report = DiagnosticsReportController(
      builder: builder,
      saveAs: saveAs,
      state: reportState,
      copyText: copyText,
      shareFile: shareFile,
      tempDirectory: tempDirectory,
      writeTempFile: writeTempFile,
      deleteTempFile: deleteTempFile,
      isDisposed: () => _disposed,
    );
    _logs = DiagnosticsLogController(
      state: logsState,
      saveAs: saveAs,
      reader: logReader,
      now: now,
      isDisposed: () => _disposed,
    );
    for (final notifier in _narrowNotifiers) {
      notifier.addListener(_onPartChanged);
    }
    _subscription = service.changes.listen((_) => _refresh());
    _refresh();
  }

  /// 变更信号（任一窄分区变化后由 provider 重新读取快照）。
  final SnapshotSignal _changes = SnapshotSignal();

  final DiagnosticsService service;
  final DiagnosticsBundleBuilder builder;
  final SaveAs saveAs;

  /// 日志复制时归一化的个人目录；null 时读取当前平台环境变量。
  final List<String>? homeDirectories;

  /// 打开外部链接；null 时用 `launchUrl`（系统外部应用）。测试可注入。
  final Future<bool> Function(Uri uri)? openExternal;

  final Future<DiagnosticsAppInfo> Function()? _appInfoLoader;
  final Future<bool> Function()? _restartEngine;
  late final DiagnosticsReportController _report;
  late final DiagnosticsLogController _logs;

  StreamSubscription<void>? _subscription;
  Future<DiagnosticsAppInfo>? _appInfoFuture;
  bool _disposed = false;

  final summary = ValueNotifier<DiagnosticsSummary>(
    const DiagnosticsSummary(tone: DiagnosticsSummaryTone.notChecked),
  );
  final checkResults = ValueNotifier<DiagnosticsChecksState>(
    const DiagnosticsChecksState(
      run: null,
      running: false,
      canStart: false,
      hasCheckableChannels: false,
    ),
  );
  final issueGroups = ValueNotifier<List<DiagnosticIssueGroup>>(const []);
  final session = ValueNotifier<DiagnosticSessionInfo?>(null);
  final appInfo = ValueNotifier<DiagnosticsAppInfo?>(null);
  final reportState = ValueNotifier(const DiagnosticsReportState());
  final logsState = ValueNotifier(
    DiagnosticsLogsState(
      status: DiagnosticsLogsStatus.idle,
      logStatus: DiagnosticLogStatus.stopped,
    ),
  );
  final metrics = ValueNotifier(const ResolveMetricsSnapshot());
  List<DiagnosticFailureRecord>? _lastFailures;
  DiagnosticSessionInfo? _lastSession;
  ResolveMetricsSnapshot? _lastMetrics;
  DiagnosticLogStatus? _lastLogStatus;
  bool get isExporting => reportState.value.busy;
  bool get hasCheckableChannels => checkResults.value.hasCheckableChannels;

  /// 页面各分区的窄订阅面（聚合快照由同一批值组成）。
  Iterable<Listenable> get _narrowNotifiers => [
    summary,
    checkResults,
    issueGroups,
    session,
    appInfo,
    reportState,
    logsState,
    metrics,
  ];

  /// 不可变聚合快照：任一窄分区变化后由 provider 重新读取。
  @override
  DiagnosticsState get state => DiagnosticsState(
    summary: summary.value,
    checkResults: checkResults.value,
    issueGroups: List.unmodifiable(issueGroups.value),
    session: session.value,
    appInfo: appInfo.value,
    reportState: reportState.value,
    logsState: logsState.value,
    metrics: metrics.value,
    isExporting: isExporting,
    hasCheckableChannels: hasCheckableChannels,
  );

  /// 变更信号（替代 `ChangeNotifier.notifyListeners` 的订阅面）。
  @override
  Listenable get changes => _changes;

  void _onPartChanged() => _changes.notify();

  /// 打开页面时读一次包信息（无网络、无磁盘扫描）；失败不阻塞页面。
  void ensureAppInfo() {
    if (appInfo.value != null || _appInfoFuture != null) return;
    final loader = _appInfoLoader;
    if (loader == null) return;
    _appInfoFuture = loader()
        .then((value) {
          if (_disposed) return value;
          appInfo.value = value;
          return value;
        })
        .catchError((Object _) {
          if (!_disposed) appInfo.value = const DiagnosticsAppInfo();
          return appInfo.value ?? const DiagnosticsAppInfo();
        });
  }

  /// 开始一轮全面检查；冷却中 / 已在跑 / 未接线时返回 false。
  Future<bool> startChecks() => service.startChecks();

  void stopChecks() => service.stopChecks();

  /// 重启音源引擎（被组合根注入）；没有接线时返回 false。
  Future<bool> restartSourceEngine() async {
    final action = _restartEngine;
    if (action == null) return false;
    try {
      return await action();
    } catch (_) {
      return false;
    }
  }

  Future<String> buildReportText({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
    int maxBytes = defaultDiagnosticsBundleMaxBytes,
  }) => _report.buildText(
    screenWidth: screenWidth,
    screenHeight: screenHeight,
    devicePixelRatio: devicePixelRatio,
    maxBytes: maxBytes,
  );

  Future<Uint8List> buildReportBytes({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
    int maxBytes = defaultDiagnosticsBundleMaxBytes,
  }) => _report.buildBytes(
    screenWidth: screenWidth,
    screenHeight: screenHeight,
    devicePixelRatio: devicePixelRatio,
    maxBytes: maxBytes,
  );

  Future<bool> copyReport({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
  }) => _report.copyReport(
    screenWidth: screenWidth,
    screenHeight: screenHeight,
    devicePixelRatio: devicePixelRatio,
  );

  Future<bool> copyPlainText(String text) => _report.copyPlainText(text);

  /// 复制日志：渲染后归一化个人目录，再走同一个剪贴板通道。
  Future<bool> copyLogEntries(List<DiagnosticLogEntry> entries) {
    final text = normalizePersonalPaths(
      renderLogEntries(entries),
      homeDirectories:
          homeDirectories ??
          [
            ?Platform.environment['HOME'],
            ?Platform.environment['USERPROFILE'],
            ?Platform.environment['LOCALAPPDATA'],
          ],
    );
    return _report.copyPlainText(text);
  }

  /// 复制脱敏报告后打开 GitHub 新建 issue 页面；报告正文只走剪贴板。
  Future<DiagnosticsReportIssueOutcome> reportIssue({
    required String version,
    required String platform,
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
  }) async {
    final copied = await copyReport(
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      devicePixelRatio: devicePixelRatio,
    );
    if (!copied) return DiagnosticsReportIssueOutcome.copyFailed;
    final uri = buildDiagnosticsIssueUri(version: version, platform: platform);
    var opened = false;
    try {
      opened = await (openExternal ?? _launchExternal)(uri);
    } catch (_) {
      opened = false;
    }
    return opened
        ? DiagnosticsReportIssueOutcome.copiedAndOpened
        : DiagnosticsReportIssueOutcome.copiedButOpenFailed;
  }

  Future<SaveAsResult> saveReport({
    String? dialogTitle,
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
  }) => _report.saveReport(
    dialogTitle: dialogTitle,
    screenWidth: screenWidth,
    screenHeight: screenHeight,
    devicePixelRatio: devicePixelRatio,
  );

  Future<DiagnosticsShareResult> shareReport({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
  }) => _report.shareReport(
    screenWidth: screenWidth,
    screenHeight: screenHeight,
    devicePixelRatio: devicePixelRatio,
  );

  Future<void> loadLogs() => _logs.loadLogs();

  Future<void> refreshLogs() => _logs.refreshLogs();

  Future<String?> logDirectoryPath() => _logs.logDirectoryPath();

  Future<bool> revealLogDirectory() => _logs.revealLogDirectory();

  void _refresh() {
    if (_disposed) return;
    _refreshSession();
    _refreshChecks();
    _refreshFailures();
    _refreshMetrics();
    _refreshLogStatus();
  }

  void _refreshSession() {
    final next = service.sessionInfo;
    if (identical(next, _lastSession)) return;
    _lastSession = next;
    session.value = next;
    _refreshSummary();
  }

  void _refreshChecks() {
    final run = service.currentCheckRun ?? service.checkRuns.firstOrNull;
    final next = DiagnosticsChecksState(
      run: run,
      running: service.runner?.running ?? false,
      canStart: service.canStartChecks,
      hasCheckableChannels: service.healthTargetCount > 0,
    );
    final current = checkResults.value;
    if (identical(current.run, next.run) &&
        current.running == next.running &&
        current.canStart == next.canStart &&
        current.hasCheckableChannels == next.hasCheckableChannels) {
      return;
    }
    checkResults.value = next;
    _refreshSummary();
  }

  void _refreshSummary() {
    final current = checkResults.value;
    final run = current.run;
    final sessionInfo = session.value;
    final tone = switch (run) {
      _ when current.running => DiagnosticsSummaryTone.running,
      null => DiagnosticsSummaryTone.notChecked,
      DiagnosticCheckRun(cancelled: true) => DiagnosticsSummaryTone.stopped,
      DiagnosticCheckRun(results: final results) when results.isEmpty =>
        DiagnosticsSummaryTone.notChecked,
      _ => DiagnosticsSummaryTone.ok,
    };
    var failed = 0;
    var warning = 0;
    var skipped = 0;
    var total = 0;
    if (run != null && !current.running) {
      for (final group in buildDiagnosticCheckGroups(run.results)) {
        for (final row in group.rows) {
          total++;
          if (row.status == DiagnosticCheckStatus.failed) failed++;
          if (row.status == DiagnosticCheckStatus.warning) warning++;
          if (row.status == DiagnosticCheckStatus.skipped) skipped++;
        }
      }
    }
    final allSkipped = total > 0 && skipped == total;
    final resolvedTone = switch (tone) {
      DiagnosticsSummaryTone.stopped => tone,
      _ when failed > 0 => DiagnosticsSummaryTone.failed,
      _ when warning > 0 => DiagnosticsSummaryTone.warning,
      _ when allSkipped => DiagnosticsSummaryTone.notChecked,
      _ => tone,
    };
    final next = DiagnosticsSummary(
      tone: resolvedTone,
      failedCount: failed,
      warningCount: warning,
      lastCheckedAt: run?.finishedAt ?? run?.startedAt,
      previousAbnormalExit: sessionInfo?.previousAbnormalExit ?? false,
      previousExitAt: sessionInfo?.previousExitAt,
      allSkipped: allSkipped,
    );
    if (_sameSummary(summary.value, next)) return;
    summary.value = next;
  }

  void _refreshFailures() {
    final records = service.failures.records;
    if (_sameFailureRecords(_lastFailures, records)) return;
    _lastFailures = records;
    issueGroups.value = groupDiagnosticFailures(records);
  }

  void _refreshMetrics() {
    final next = service.metrics.snapshot();
    if (_sameMetrics(_lastMetrics, next)) return;
    _lastMetrics = next;
    metrics.value = next;
  }

  void _refreshLogStatus() {
    final next = service.logStatus;
    final current = logsState.value;
    if (_lastLogStatus == next) return;
    _lastLogStatus = next;
    logsState.value = DiagnosticsLogsState(
      status: current.status,
      logStatus: next,
      entries: current.entries,
      loadedAt: current.loadedAt,
    );
  }

  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    for (final notifier in _narrowNotifiers) {
      notifier.removeListener(_onPartChanged);
    }
    summary.dispose();
    checkResults.dispose();
    issueGroups.dispose();
    session.dispose();
    appInfo.dispose();
    reportState.dispose();
    logsState.dispose();
    metrics.dispose();
  }
}

Future<bool> _launchExternal(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

bool _sameSummary(DiagnosticsSummary a, DiagnosticsSummary b) =>
    a.tone == b.tone &&
    a.failedCount == b.failedCount &&
    a.warningCount == b.warningCount &&
    a.lastCheckedAt == b.lastCheckedAt &&
    a.previousAbnormalExit == b.previousAbnormalExit &&
    a.previousExitAt == b.previousExitAt &&
    a.allSkipped == b.allSkipped;

bool _sameFailureRecords(
  List<DiagnosticFailureRecord>? previous,
  List<DiagnosticFailureRecord> next,
) {
  if (previous == null || previous.length != next.length) return false;
  for (var index = 0; index < next.length; index++) {
    if (!identical(previous[index], next[index])) return false;
  }
  return true;
}

bool _sameMetrics(
  ResolveMetricsSnapshot? previous,
  ResolveMetricsSnapshot next,
) {
  if (previous == null) return false;
  if (previous.calls != next.calls ||
      previous.cacheHits != next.cacheHits ||
      previous.retries != next.retries ||
      previous.successes != next.successes ||
      previous.failures != next.failures ||
      previous.timeouts != next.timeouts ||
      previous.failuresByKind.length != next.failuresByKind.length) {
    return false;
  }
  for (final entry in next.failuresByKind.entries) {
    if (previous.failuresByKind[entry.key] != entry.value) return false;
  }
  return true;
}
