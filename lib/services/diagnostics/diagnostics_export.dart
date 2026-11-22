/// 诊断导出器：汇总快照 → 在后台 isolate 读取日志 / 脱敏 / 组装 → UTF-8 字节。
///
/// 不联网、不申请新权限；设置 / 渠道 / 数据库 / 应用信息的读取全部由注入的
/// gatherer 完成，缺失的子系统只产生说明行，不会让整份导出失败。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'app_info.dart';
import 'diagnostics_bundle.dart';
import '../../domain/models/diagnostics.dart';
import 'diagnostics_service.dart';

typedef DiagnosticsSettingsGatherer =
    Future<DiagnosticsSettingsSnapshot> Function();
typedef DiagnosticsSourcesGatherer =
    Future<DiagnosticsSourcesSnapshot> Function();
typedef DiagnosticsDatabaseGatherer =
    Future<DiagnosticsDatabaseCounts> Function();

/// 导出器接口（页面 / provider 只依赖它；测试可注入假实现）。
abstract interface class DiagnosticsBundleBuilder {
  String suggestedFileName([DateTime? at]);

  Future<Uint8List> buildBytes({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
    int maxBytes = defaultDiagnosticsBundleMaxBytes,
  });

  Future<String> buildText({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
    int maxBytes = defaultDiagnosticsBundleMaxBytes,
  });
}

class DiagnosticsExporter implements DiagnosticsBundleBuilder {
  DiagnosticsExporter({
    required this.service,
    required this.appInfo,
    required this.settings,
    required this.sources,
    required this.database,
    this._logDirectory,
    DateTime Function()? now,
    this.runInIsolate = true,
  }) : _now = now ?? DateTime.now;

  final DiagnosticsService service;
  final DiagnosticsAppInfoGatherer appInfo;
  final DiagnosticsSettingsGatherer settings;
  final DiagnosticsSourcesGatherer sources;
  final DiagnosticsDatabaseGatherer database;
  final Future<Directory?> Function()? _logDirectory;
  final DateTime Function() _now;
  final bool runInIsolate;

  /// 文件名沿用现有导出命名（本地时间戳 + `.txt`）。
  @override
  String suggestedFileName([DateTime? at]) {
    final stamp = (at ?? _now())
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return 'molia_diagnostics_$stamp.txt';
  }

  @override
  Future<Uint8List> buildBytes({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
    int maxBytes = defaultDiagnosticsBundleMaxBytes,
  }) async {
    final job = await _gather(
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      devicePixelRatio: devicePixelRatio,
      maxBytes: maxBytes,
    );
    if (!runInIsolate) return _renderJobBytes(job);
    try {
      return await Isolate.run(() => _renderJobBytes(job));
    } catch (_) {
      // 极少数受限宿主无法起 isolate：回退同步组装，导出仍然可用。
      return _renderJobBytes(job);
    }
  }

  /// 仅测试 / 调试用；UTF-8 编码也在 isolate 内完成（见 [buildBytes]）。
  @override
  Future<String> buildText({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
    int maxBytes = defaultDiagnosticsBundleMaxBytes,
  }) async => utf8.decode(
    await buildBytes(
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      devicePixelRatio: devicePixelRatio,
      maxBytes: maxBytes,
    ),
  );

  Future<_BundleJob> _gather({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
    int maxBytes = defaultDiagnosticsBundleMaxBytes,
  }) async {
    final app = (await appInfo.load()).copyWith(
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      devicePixelRatio: devicePixelRatio,
    );
    DiagnosticsSettingsSnapshot settingsSnapshot;
    try {
      settingsSnapshot = await settings();
    } catch (_) {
      settingsSnapshot = const DiagnosticsSettingsSnapshot(
        notes: ['Settings snapshot unavailable.'],
      );
    }
    DiagnosticsSourcesSnapshot sourcesSnapshot;
    try {
      sourcesSnapshot = await sources();
    } catch (_) {
      sourcesSnapshot = const DiagnosticsSourcesSnapshot(
        notes: ['Source snapshot unavailable.'],
      );
    }
    DiagnosticsDatabaseCounts? databaseSnapshot;
    String? databaseNote;
    try {
      databaseSnapshot = await database();
    } catch (_) {
      databaseNote = 'Database counts unavailable.';
    }
    // 导出前把队列里的最后一批日志落盘，并 flush 问题历史（去抖中的写入），
    // 避免漏掉最近约 1 秒的记录。两者自身有界且不抛异常；不可用只影响对应段。
    try {
      await service.flushPendingWrites();
    } catch (_) {
      // 日志 / 历史不可用不阻塞其余诊断段。
    }
    Directory? logDir;
    try {
      logDir = await _logDirectory?.call();
    } catch (_) {
      logDir = null;
    }
    return _BundleJob(
      generatedAt: _now(),
      timezoneOffset: _now().timeZoneOffset,
      app: app,
      settings: settingsSnapshot,
      sources: sourcesSnapshot,
      failures: List<DiagnosticFailureRecord>.of(service.failures.records),
      healthRuns: List<HealthRun>.of(service.healthRuns),
      checks: List<DiagnosticCheckRun>.of(service.checkRuns),
      session: service.sessionInfo,
      playbackAttempts: List<PlaybackAttempt>.of(service.playbackAttempts),
      issues: List<DiagnosticIssueGroup>.of(service.issues),
      database: databaseSnapshot,
      databaseNote: databaseNote,
      logDirectoryPath: logDir?.path,
      maxBytes: maxBytes,
    );
  }
}

class _BundleJob {
  const _BundleJob({
    required this.generatedAt,
    required this.timezoneOffset,
    required this.app,
    required this.settings,
    required this.sources,
    required this.failures,
    required this.healthRuns,
    required this.checks,
    required this.session,
    required this.playbackAttempts,
    required this.issues,
    required this.database,
    required this.databaseNote,
    required this.logDirectoryPath,
    required this.maxBytes,
  });

  final DateTime generatedAt;
  final Duration timezoneOffset;
  final DiagnosticsAppInfo app;
  final DiagnosticsSettingsSnapshot settings;
  final DiagnosticsSourcesSnapshot sources;
  final List<DiagnosticFailureRecord> failures;
  final List<HealthRun> healthRuns;
  final List<DiagnosticCheckRun> checks;
  final DiagnosticSessionInfo? session;
  final List<PlaybackAttempt> playbackAttempts;
  final List<DiagnosticIssueGroup> issues;
  final DiagnosticsDatabaseCounts? database;
  final String? databaseNote;
  final String? logDirectoryPath;
  final int maxBytes;
}

Uint8List _renderJobBytes(_BundleJob job) =>
    Uint8List.fromList(utf8.encode(_renderJob(job)));

String _renderJob(_BundleJob job) {
  final logs = <DiagnosticsLogFile>[];
  String? logsNote;
  final path = job.logDirectoryPath;
  if (path == null) {
    logsNote =
        'Local log directory is unavailable; no log files were included.';
  } else {
    try {
      final files = _retainedLogFiles(Directory(path));
      for (final file in files) {
        try {
          final bytes = file.readAsBytesSync();
          logs.add(
            DiagnosticsLogFile(
              name: file.uri.pathSegments.isEmpty
                  ? file.path
                  : file.uri.pathSegments.last,
              content: utf8.decode(bytes, allowMalformed: true),
            ),
          );
        } catch (_) {
          logsNote = 'One or more log files could not be read.';
        }
      }
      if (logs.isEmpty && logsNote == null) {
        logsNote = 'No retained log files were found.';
      }
    } catch (_) {
      logsNote = 'The local log directory could not be read.';
    }
  }
  final data = DiagnosticsBundleData(
    generatedAt: job.generatedAt,
    timezoneOffset: job.timezoneOffset,
    app: job.app,
    settings: job.settings,
    sources: job.sources,
    failures: job.failures,
    healthRuns: job.healthRuns,
    checks: job.checks,
    session: job.session,
    playbackAttempts: job.playbackAttempts,
    issues: job.issues,
    database: job.database,
    databaseNote: job.databaseNote,
    logs: logs,
    logsNote: logsNote,
    homeDirectories: [
      ?Platform.environment['HOME'],
      ?Platform.environment['USERPROFILE'],
      ?Platform.environment['LOCALAPPDATA'],
    ],
  );
  return renderDiagnosticsBundle(data, maxBytes: job.maxBytes);
}

/// 活动文件最后、归档从旧到新（`molia.2.log` → `molia.1.log` → `molia.log`）。
List<File> _retainedLogFiles(Directory directory) {
  if (!directory.existsSync()) return const [];
  final active = <File>[];
  final archives = <({int index, File file})>[];
  for (final entity in directory.listSync(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.isEmpty
        ? entity.path
        : entity.uri.pathSegments.last;
    if (name == 'molia.log') {
      active.add(entity);
      continue;
    }
    final match = RegExp(r'^molia\.(\d+)\.log$').firstMatch(name);
    if (match == null) continue;
    archives.add((index: int.parse(match.group(1)!), file: entity));
  }
  archives.sort((a, b) => b.index.compareTo(a.index));
  return [for (final archive in archives) archive.file, ...active];
}
