/// 问题排查页的分区状态：把诊断服务的只读快照投影成按分区订阅的
/// [ValueListenable]，页面各卡片只重建自己关心的那一份。
///
/// provider 挂在根 Provider 树、与应用同生命周期，只做快照投影与动作转发；
/// 不 import 页面，也不在页面未打开时发起检查 / 日志读取。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/models/diagnostics.dart';
import '../services/diagnostics/diagnostics_bundle.dart';
import '../services/diagnostics/diagnostics_export.dart';
import '../services/diagnostics/diagnostics_service.dart';
import '../services/diagnostics/log_tail_reader.dart';
import '../services/diagnostics/resolve_metrics.dart';
import '../services/save_as.dart';

/// 报告预览的读取上限：预览只需要一眼能读完的结论与日志末尾。
const int diagnosticsReportPreviewMaxBytes = 64 * 1024;

/// 摘要结论（一句话状态）。
enum DiagnosticsSummaryTone {
  notChecked,
  running,
  ok,
  warning,
  failed,
  stopped,
}

/// 状态摘要卡读取的窄快照。
class DiagnosticsSummary {
  const DiagnosticsSummary({
    required this.tone,
    this.failedCount = 0,
    this.warningCount = 0,
    this.lastCheckedAt,
    this.previousAbnormalExit = false,
    this.previousExitAt,
  });

  final DiagnosticsSummaryTone tone;
  final int failedCount;
  final int warningCount;
  final DateTime? lastCheckedAt;
  final bool previousAbnormalExit;
  final DateTime? previousExitAt;

  bool get running => tone == DiagnosticsSummaryTone.running;
}

/// 检查结果分区：当前运行（或最近一轮）+ 可执行状态。
class DiagnosticsChecksState {
  const DiagnosticsChecksState({
    required this.run,
    required this.running,
    required this.canStart,
    required this.hasCheckableChannels,
  });

  final DiagnosticCheckRun? run;
  final bool running;
  final bool canStart;
  final bool hasCheckableChannels;

  List<DiagnosticCheckResult> get results => run?.results ?? const [];
}

/// 报告动作阶段（顶栏图标据此禁用并显示进度）。
enum DiagnosticsReportStage { idle, preparing, saving, sharing }

class DiagnosticsReportState {
  const DiagnosticsReportState({this.stage = DiagnosticsReportStage.idle});

  final DiagnosticsReportStage stage;

  bool get busy => stage != DiagnosticsReportStage.idle;
}

/// 日志子页的加载状态。
enum DiagnosticsLogsStatus { idle, loading, ready, unavailable, failed }

class DiagnosticsLogsState {
  const DiagnosticsLogsState({
    required this.status,
    required this.logStatus,
    this.entries = const [],
    this.loadedAt,
  });

  final DiagnosticsLogsStatus status;

  /// 文件日志 sink 自身的状态（正在记录 / 已停止 / 不可用）。
  final DiagnosticLogStatus logStatus;

  final List<DiagnosticLogEntry> entries;
  final DateTime? loadedAt;
}

/// 分享结果：成功、平台不支持时退化为保存、或失败。
enum DiagnosticsShareOutcome { shared, savedFallback, failed }

class DiagnosticsShareResult {
  const DiagnosticsShareResult(this.outcome, {this.saved});

  final DiagnosticsShareOutcome outcome;

  /// 退化保存时的结果；用户取消 / 失败时保留原始类型。
  final SaveAsResult? saved;
}

/// 页面按渠道合并后的检查行：渠道检查三步收一行，非渠道检查一行一项。
class DiagnosticCheckRow {
  DiagnosticCheckRow({
    required this.group,
    required this.status,
    required Map<DiagnosticCheckId, DiagnosticCheckResult> steps,
    required this.latencyMs,
    this.id,
    this.channelKey,
    this.channelDisplayName,
  }) : steps = Map<DiagnosticCheckId, DiagnosticCheckResult>.unmodifiable(
         steps,
       );

  final DiagnosticCheckGroup group;
  final DiagnosticCheckStatus status;
  final Map<DiagnosticCheckId, DiagnosticCheckResult> steps;
  final int latencyMs;

  /// 非渠道检查的稳定 id；渠道行由 [channelKey] 标识。
  final DiagnosticCheckId? id;
  final String? channelKey;
  final String? channelDisplayName;

  bool get isChannel => channelKey != null;

  String get rowKey => channelKey ?? id!.name;

  /// 渠道行按固定顺序取步骤；缺失表示本轮没有执行。
  DiagnosticCheckResult? step(DiagnosticCheckId stepId) => steps[stepId];
}

/// 一个分组下的检查行（失败置顶，其余按扫描顺序稳定展示）。
class DiagnosticsCheckGroupView {
  DiagnosticsCheckGroupView({required this.group, required this.rows});

  final DiagnosticCheckGroup group;
  final List<DiagnosticCheckRow> rows;
}

const List<DiagnosticCheckGroup> diagnosticCheckGroupOrder = [
  DiagnosticCheckGroup.app,
  DiagnosticCheckGroup.sources,
  DiagnosticCheckGroup.playback,
  DiagnosticCheckGroup.storage,
  DiagnosticCheckGroup.sync,
];

const Set<DiagnosticCheckId> _channelCheckIds = {
  DiagnosticCheckId.channelSearch,
  DiagnosticCheckId.channelResolve,
  DiagnosticCheckId.channelStream,
};

/// 把扁平结果投影成「渠道合并 + 失败置顶」的分组视图。
///
/// 纯函数：不改写结果，只按只读记录分组；同一渠道的搜索 / 取链 / 播放流
/// 合并成一行，其它检查一行一项。
List<DiagnosticsCheckGroupView> buildDiagnosticCheckGroups(
  Iterable<DiagnosticCheckResult> results,
) {
  final rows = <DiagnosticCheckRow>[];
  final channelRows = <String, _ChannelRowBuilder>{};
  for (final result in results) {
    final channelKey = result.channelKey;
    if (_channelCheckIds.contains(result.id) && channelKey != null) {
      final builder = channelRows.putIfAbsent(
        channelKey,
        () => _ChannelRowBuilder(
          channelKey: channelKey,
          channelDisplayName: result.channelDisplayName ?? channelKey,
        ),
      );
      builder
        ..steps[result.id] = result
        ..latencyMs += result.latencyMs;
      continue;
    }
    rows.add(
      DiagnosticCheckRow(
        id: result.id,
        group: result.group,
        status: result.status,
        steps: {result.id: result},
        latencyMs: result.latencyMs,
      ),
    );
  }
  rows.addAll(channelRows.values.map((builder) => builder.build()));

  final Map<DiagnosticCheckGroup, List<DiagnosticCheckRow>> grouped = {};
  for (final row in rows) {
    grouped.putIfAbsent(row.group, () => []).add(row);
  }
  return [
    for (final group in diagnosticCheckGroupOrder)
      if (grouped[group]?.isNotEmpty ?? false)
        DiagnosticsCheckGroupView(
          group: group,
          rows: grouped[group]!..sort(_compareCheckRows),
        ),
  ];
}

int _statusRank(DiagnosticCheckStatus status) => switch (status) {
  DiagnosticCheckStatus.failed => 0,
  DiagnosticCheckStatus.warning => 1,
  DiagnosticCheckStatus.skipped => 2,
  DiagnosticCheckStatus.ok => 3,
};

int _compareCheckRows(DiagnosticCheckRow a, DiagnosticCheckRow b) {
  final byStatus = _statusRank(a.status).compareTo(_statusRank(b.status));
  if (byStatus != 0) return byStatus;
  return a.rowKey.compareTo(b.rowKey);
}

class _ChannelRowBuilder {
  _ChannelRowBuilder({
    required this.channelKey,
    required this.channelDisplayName,
  });

  final String channelKey;
  final String channelDisplayName;
  final Map<DiagnosticCheckId, DiagnosticCheckResult> steps = {};
  int latencyMs = 0;

  DiagnosticCheckRow build() {
    var status = DiagnosticCheckStatus.ok;
    for (final step in steps.values) {
      if (step.status == DiagnosticCheckStatus.failed) {
        status = DiagnosticCheckStatus.failed;
        break;
      }
      if (step.status == DiagnosticCheckStatus.warning) {
        status = DiagnosticCheckStatus.warning;
      }
    }
    return DiagnosticCheckRow(
      group: DiagnosticCheckGroup.sources,
      status: status,
      steps: steps,
      latencyMs: latencyMs,
      channelKey: channelKey,
      channelDisplayName: channelDisplayName,
    );
  }
}

typedef DiagnosticsCopyText = Future<void> Function(String text);
typedef DiagnosticsShareFile = Future<void> Function(String path);

/// 分享前的临时文件写入（默认写系统临时目录）；测试可注入内存实现。
typedef DiagnosticsTempFileWriter = Future<String> Function(
  String fileName,
  Uint8List bytes,
);

/// 页面状态与动作的唯一入口；所有通知都走窄 [ValueListenable]。
class DiagnosticsProvider extends ChangeNotifier {
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
    DateTime Function()? now,
  }) : _appInfoLoader = appInfo,
       // ignore: prefer_initializing_formals
       _restartEngine = restartEngine,
       // ignore: prefer_initializing_formals
       _logReader = logReader,
       // ignore: prefer_initializing_formals
       _copyText = copyText,
       // ignore: prefer_initializing_formals
       _shareFile = shareFile,
       // ignore: prefer_initializing_formals
       _tempDirectory = tempDirectory,
       // ignore: prefer_initializing_formals
       _writeTempFile = writeTempFile,
       _now = now ?? DateTime.now {
    _subscription = service.changes.listen((_) => _refresh());
    _refresh();
  }

  final DiagnosticsService service;
  final DiagnosticsBundleBuilder builder;
  final SaveAs saveAs;
  final Future<DiagnosticsAppInfo> Function()? _appInfoLoader;
  final Future<bool> Function()? _restartEngine;
  final LogTailReader? _logReader;
  final DiagnosticsCopyText? _copyText;
  final DiagnosticsShareFile? _shareFile;
  final Future<Directory> Function()? _tempDirectory;
  final DiagnosticsTempFileWriter? _writeTempFile;
  final DateTime Function() _now;
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
  bool _readingLogs = false;
  bool get isExporting => reportState.value.busy;
  bool get hasCheckableChannels => checkResults.value.hasCheckableChannels;

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
  }) => builder.buildText(
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
  }) => builder.buildBytes(
    screenWidth: screenWidth,
    screenHeight: screenHeight,
    devicePixelRatio: devicePixelRatio,
    maxBytes: maxBytes,
  );

  /// 复制报告：独立小上限（128 KB），只含结论、问题组与日志末尾。
  Future<bool> copyReport({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
  }) async {
    if (reportState.value.busy) return false;
    _setReportStage(DiagnosticsReportStage.preparing);
    try {
      final text = await buildReportText(
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        devicePixelRatio: devicePixelRatio,
        maxBytes: diagnosticsCopyMaxBytes,
      );
      return await copyPlainText(text);
    } catch (_) {
      return false;
    } finally {
      _setReportStage(DiagnosticsReportStage.idle);
    }
  }

  /// 普通文本复制（检查 / 问题详情、日志结果共用同一注入通道）。
  Future<bool> copyPlainText(String text) async {
    try {
      final copy = _copyText;
      if (copy != null) {
        await copy(text);
      } else {
        await Clipboard.setData(ClipboardData(text: text));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 保存完整诊断文件（20 MB 上限沿用导出器）。
  Future<SaveAsResult> saveReport({
    String? dialogTitle,
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
  }) async {
    if (reportState.value.busy) return const SaveAsFailed();
    _setReportStage(DiagnosticsReportStage.saving);
    try {
      final bytes = await buildReportBytes(
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        devicePixelRatio: devicePixelRatio,
      );
      return await _saveBytes(bytes, dialogTitle: dialogTitle);
    } catch (error) {
      return SaveAsFailed(error);
    } finally {
      _setReportStage(DiagnosticsReportStage.idle);
    }
  }

  /// 分享报告：写临时文件后走系统分享；平台不支持文件分享时退化为保存。
  Future<DiagnosticsShareResult> shareReport({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
  }) async {
    if (reportState.value.busy) {
      return const DiagnosticsShareResult(DiagnosticsShareOutcome.failed);
    }
    _setReportStage(DiagnosticsReportStage.preparing);
    try {
      final bytes = await buildReportBytes(
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        devicePixelRatio: devicePixelRatio,
      );
      _setReportStage(DiagnosticsReportStage.sharing);
      final fileName = builder.suggestedFileName();
      final path =
          await _writeTempFile?.call(fileName, bytes) ??
          await _writeDefaultTempFile(fileName, bytes);
      try {
        final share = _shareFile;
        if (share != null) {
          await share(path);
        } else {
          await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
        }
        return const DiagnosticsShareResult(DiagnosticsShareOutcome.shared);
      } catch (_) {
        final saved = await _saveBytes(bytes, dialogTitle: null);
        return DiagnosticsShareResult(
          DiagnosticsShareOutcome.savedFallback,
          saved: saved,
        );
      }
    } catch (_) {
      return const DiagnosticsShareResult(DiagnosticsShareOutcome.failed);
    } finally {
      _setReportStage(DiagnosticsReportStage.idle);
    }
  }

  /// 打开日志子页时读取一次有界尾部；已加载 / 正在加载时不重复读盘。
  Future<void> loadLogs() async {
    final state = logsState.value;
    if (_readingLogs ||
        state.status == DiagnosticsLogsStatus.ready ||
        state.status == DiagnosticsLogsStatus.unavailable) {
      return;
    }
    await _readLogs();
  }

  /// 用户主动刷新：总是重新读取。
  Future<void> refreshLogs() => _readLogs();

  Future<String?> logDirectoryPath() async {
    try {
      final directory = await _logReader?.directory();
      return directory?.path;
    } catch (_) {
      return null;
    }
  }

  /// 打开日志目录（用另存服务的定位入口）；不可用时返回 false。
  Future<bool> revealLogDirectory() async {
    final path = await logDirectoryPath();
    if (path == null || path.isEmpty) return false;
    try {
      return await saveAs.reveal(path);
    } catch (_) {
      return false;
    }
  }

  Future<String> _writeDefaultTempFile(String fileName, Uint8List bytes) async {
    final directory = await (_tempDirectory?.call() ?? getTemporaryDirectory());
    final file = File(p.join(directory.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<SaveAsResult> _saveBytes(
    Uint8List bytes, {
    String? dialogTitle,
  }) async {
    try {
      return await saveAs.saveBytes(
        fileName: builder.suggestedFileName(),
        bytes: bytes,
        mimeType: 'text/plain',
        relativeDir: saveAsExportsDirName,
        dialogTitle: dialogTitle,
      );
    } catch (error) {
      return SaveAsFailed(error);
    }
  }

  void _setReportStage(DiagnosticsReportStage stage) {
    if (_disposed) return;
    if (reportState.value.stage == stage) return;
    reportState.value = DiagnosticsReportState(stage: stage);
  }

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
    if (run != null && !current.running) {
      for (final group in buildDiagnosticCheckGroups(run.results)) {
        for (final row in group.rows) {
          if (row.status == DiagnosticCheckStatus.failed) failed++;
          if (row.status == DiagnosticCheckStatus.warning) warning++;
        }
      }
    }
    final resolvedTone = failed > 0
        ? DiagnosticsSummaryTone.failed
        : warning > 0
        ? DiagnosticsSummaryTone.warning
        : tone;
    final next = DiagnosticsSummary(
      tone: resolvedTone,
      failedCount: failed,
      warningCount: warning,
      lastCheckedAt: run?.finishedAt ?? run?.startedAt,
      previousAbnormalExit: sessionInfo?.previousAbnormalExit ?? false,
      previousExitAt: sessionInfo?.previousExitAt,
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

  Future<void> _readLogs() async {
    if (_readingLogs) return;
    _readingLogs = true;
    final current = logsState.value;
    _setLogsState(
      DiagnosticsLogsState(
        status: DiagnosticsLogsStatus.loading,
        logStatus: current.logStatus,
        entries: current.entries,
        loadedAt: current.loadedAt,
      ),
    );
    try {
      final reader = _logReader;
      if (reader == null) {
        _setLogsState(
          DiagnosticsLogsState(
            status: DiagnosticsLogsStatus.unavailable,
            logStatus: logsState.value.logStatus,
          ),
        );
        return;
      }
      Directory? directory;
      try {
        directory = await reader.directory();
      } catch (_) {
        directory = null;
      }
      if (directory == null) {
        _setLogsState(
          DiagnosticsLogsState(
            status: DiagnosticsLogsStatus.unavailable,
            logStatus: logsState.value.logStatus,
          ),
        );
        return;
      }
      final entries = await reader.read();
      _setLogsState(
        DiagnosticsLogsState(
          status: DiagnosticsLogsStatus.ready,
          logStatus: logsState.value.logStatus,
          entries: entries,
          loadedAt: _now(),
        ),
      );
    } catch (_) {
      _setLogsState(
        DiagnosticsLogsState(
          status: DiagnosticsLogsStatus.failed,
          logStatus: logsState.value.logStatus,
        ),
      );
    } finally {
      _readingLogs = false;
    }
  }

  void _setLogsState(DiagnosticsLogsState state) {
    if (_disposed) return;
    logsState.value = state;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    summary.dispose();
    checkResults.dispose();
    issueGroups.dispose();
    session.dispose();
    appInfo.dispose();
    reportState.dispose();
    logsState.dispose();
    metrics.dispose();
    super.dispose();
  }
}

bool _sameSummary(DiagnosticsSummary a, DiagnosticsSummary b) =>
    a.tone == b.tone &&
    a.failedCount == b.failedCount &&
    a.warningCount == b.warningCount &&
    a.lastCheckedAt == b.lastCheckedAt &&
    a.previousAbnormalExit == b.previousAbnormalExit &&
    a.previousExitAt == b.previousExitAt;

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
