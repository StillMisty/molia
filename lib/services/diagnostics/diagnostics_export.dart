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
import 'diagnostics_service.dart';
import 'failure_ring_buffer.dart';
import 'source_health_checker.dart';

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
  });

  Future<String> buildText({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
  });
}

class DiagnosticsExporter implements DiagnosticsBundleBuilder {
  DiagnosticsExporter({
    required this.service,
    required this.appInfo,
    required this.settings,
    required this.sources,
    required this.database,
    Future<Directory?> Function()? logDirectory,
    DateTime Function()? now,
    this.runInIsolate = true,
  }) : _logDirectory = logDirectory,
       _now = now ?? DateTime.now;

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
  }) async => Uint8List.fromList(
    utf8.encode(
      await buildText(
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        devicePixelRatio: devicePixelRatio,
      ),
    ),
  );

  @override
  Future<String> buildText({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
  }) async {
    final job = await _gather(
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      devicePixelRatio: devicePixelRatio,
    );
    if (!runInIsolate) return _renderJob(job);
    try {
      return await Isolate.run(() => _renderJob(job));
    } catch (_) {
      // 极少数受限宿主无法起 isolate：回退同步组装，导出仍然可用。
      return _renderJob(job);
    }
  }

  Future<_BundleJob> _gather({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
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
      database: databaseSnapshot,
      databaseNote: databaseNote,
      logDirectoryPath: logDir?.path,
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
    required this.database,
    required this.databaseNote,
    required this.logDirectoryPath,
  });

  final DateTime generatedAt;
  final Duration timezoneOffset;
  final DiagnosticsAppInfo app;
  final DiagnosticsSettingsSnapshot settings;
  final DiagnosticsSourcesSnapshot sources;
  final List<DiagnosticFailureRecord> failures;
  final List<HealthRun> healthRuns;
  final DiagnosticsDatabaseCounts? database;
  final String? databaseNote;
  final String? logDirectoryPath;
}

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
    database: job.database,
    databaseNote: job.databaseNote,
    logs: logs,
    logsNote: logsNote,
    homeDirectories: [
      if (Platform.environment['HOME'] case final home?) home,
      if (Platform.environment['USERPROFILE'] case final home?) home,
      if (Platform.environment['LOCALAPPDATA'] case final home?) home,
    ],
  );
  return renderDiagnosticsBundle(data);
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
