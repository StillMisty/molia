import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/diagnostics.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/providers/diagnostics_provider.dart';
import 'package:molia/services/diagnostics/diagnostics_bundle.dart';
import 'package:molia/services/diagnostics/diagnostics_export.dart';
import 'package:molia/services/diagnostics/diagnostics_runner.dart';
import 'package:molia/services/diagnostics/diagnostics_service.dart';
import 'package:molia/services/diagnostics/diagnostics_session_store.dart';
import 'package:molia/services/diagnostics/failure_ring_buffer.dart';
import 'package:molia/services/diagnostics/log_tail_reader.dart';
import 'package:molia/services/diagnostics/resolve_metrics.dart';
import 'package:molia/services/save_as.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_save_as.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  late DiagnosticsService service;
  late FakeSaveAs saveAs;
  late _RecordingBuilder builder;
  late List<String> copied;
  late Directory logDir;
  late DiagnosticsProvider provider;

  Future<DiagnosticsProvider> buildProvider({
    List<DiagnosticCheck> checks = const [],
    DiagnosticSessionTracker? session,
    Future<void> Function(String path)? shareFile,
    Future<bool> Function()? restartEngine,
    DiagnosticsTempFileWriter? writeTempFile,
    Future<void> Function(String path)? deleteTempFile,
    List<String>? homeDirectories,
  }) async {
    service = DiagnosticsService(
      failures: FailureRingBuffer(),
      metrics: ResolveMetrics(),
      session: session,
    );
    if (checks.isNotEmpty) {
      service.attachRunner(DiagnosticsRunner(checks: checks));
    }
    saveAs = FakeSaveAs();
    builder = _RecordingBuilder();
    copied = [];
    logDir = await Directory.systemTemp.createTemp('molia_diag_provider_');
    addTearDown(() async {
      if (await logDir.exists()) await logDir.delete(recursive: true);
    });
    provider = DiagnosticsProvider(
      service: service,
      builder: builder,
      saveAs: saveAs,
      appInfo: () async => const DiagnosticsAppInfo(
        version: '9.9.9',
        buildNumber: '42',
        platform: 'linux',
      ),
      logReader: LogTailReader(directory: () async => logDir),
      copyText: (text) async => copied.add(text),
      shareFile: shareFile,
      tempDirectory: () async => logDir,
      writeTempFile: writeTempFile,
      deleteTempFile: deleteTempFile,
      homeDirectories: homeDirectories,
      restartEngine: restartEngine,
    );
    addTearDown(() async {
      provider.dispose();
      await service.dispose();
    });
    return provider;
  }

  test('包信息读一次，失败回退 unknown', () async {
    await buildProvider();
    provider.ensureAppInfo();
    await pumpEventQueue();
    expect(provider.appInfo.value?.version, '9.9.9');
    expect(provider.appInfo.value?.platform, 'linux');

    final fallback = DiagnosticsProvider(
      service: service,
      builder: builder,
      saveAs: saveAs,
      appInfo: () async => throw StateError('package info unavailable'),
    );
    addTearDown(fallback.dispose);
    fallback.ensureAppInfo();
    await pumpEventQueue();
    expect(fallback.appInfo.value?.version, 'unknown');
  });

  test('开始检查后摘要与结果分区更新，其它分区不重建', () async {
    final check = _DeferredCheck();
    await buildProvider(checks: [check]);
    var groups = 0;
    var metrics = 0;
    parser() {
      provider.issueGroups.addListener(() => groups++);
      provider.metrics.addListener(() => metrics++);
    }

    parser();
    final started = await provider.startChecks();
    await pumpEventQueue();
    expect(started, isTrue);
    expect(provider.summary.value.tone, DiagnosticsSummaryTone.running);
    expect(provider.checkResults.value.running, isTrue);

    check.release();
    await service.runner!.idle;
    await pumpEventQueue();
    expect(provider.summary.value.tone, DiagnosticsSummaryTone.ok);
    expect(provider.checkResults.value.run?.results, isNotEmpty);
    expect(groups, 0);
    expect(metrics, 0);
  });

  test('问题组只随失败记录重建，不随取链指标变化', () async {
    await buildProvider();
    service.recordFailure(
      failure: const SourceFailure(kind: FailureKind.network, message: ''),
      channelKey: 'kw',
      channelDisplayName: '酷我',
    );
    await pumpEventQueue();
    final first = provider.issueGroups.value;
    expect(first, hasLength(1));
    expect(first.single.count, 1);

    var rebuilds = 0;
    provider.issueGroups.addListener(() => rebuilds++);
    service.metrics
      ..recordCall()
      ..recordCacheHit();
    await pumpEventQueue();
    expect(provider.issueGroups.value, same(first));
    expect(rebuilds, 0);
    expect(provider.metrics.value.calls, 1);

    service.recordFailure(
      failure: const SourceFailure(kind: FailureKind.network, message: ''),
      channelKey: 'kw',
      channelDisplayName: '酷我',
    );
    await pumpEventQueue();
    expect(rebuilds, 1);
    expect(provider.issueGroups.value.single.count, 2);
  });

  test('摘要包含上次异常退出标记', () async {
    await buildProvider(session: _FakeSession(_abnormalSession()));
    await pumpEventQueue();
    expect(provider.summary.value.previousAbnormalExit, isTrue);
    expect(provider.session.value?.previousAbnormalExit, isTrue);
  });

  test('复制报告使用 128 KB 小上限并走注入复制通道', () async {
    await buildProvider();
    expect(await provider.copyReport(), isTrue);
    expect(builder.textMaxBytes, diagnosticsCopyMaxBytes);
    expect(copied.single, 'diagnostics text');
  });

  test('保存报告使用完整上限与 exports 目录', () async {
    await buildProvider();
    final result = await provider.saveReport(dialogTitle: 'save');
    expect(result, isA<SaveAsSaved>());
    expect(builder.bytesMaxBytes, defaultDiagnosticsBundleMaxBytes);
    expect(saveAs.saves.single.relativeDir, 'exports');
    expect(saveAs.saves.single.fileName, 'molia_diagnostics_test.txt');
  });

  test('分享成功后清理临时文件', () async {
    final deleted = <String>[];
    await buildProvider(
      shareFile: (_) async {},
      writeTempFile: (name, bytes) async => '/tmp/$name',
      deleteTempFile: (path) async => deleted.add(path),
    );
    final result = await provider.shareReport();
    expect(result.outcome, DiagnosticsShareOutcome.shared);
    expect(deleted, ['/tmp/molia_diagnostics_test.txt']);
  });

  test('分享失败退化为保存后也清理临时文件', () async {
    final deleted = <String>[];
    await buildProvider(
      shareFile: (_) async => throw StateError('share unavailable'),
      writeTempFile: (name, bytes) async => '/tmp/$name',
      deleteTempFile: (path) async => deleted.add(path),
    );
    final result = await provider.shareReport();
    expect(result.outcome, DiagnosticsShareOutcome.savedFallback);
    expect(result.saved, isA<SaveAsSaved>());
    expect(saveAs.saves, hasLength(1));
    expect(deleted, ['/tmp/molia_diagnostics_test.txt']);
  });

  test('全部 skipped 不显示一切正常', () async {
    await buildProvider(checks: [_SkippedCheck()]);
    expect(await provider.startChecks(), isTrue);
    await service.runner!.idle;
    await pumpEventQueue();
    expect(provider.summary.value.tone, DiagnosticsSummaryTone.notChecked);
    expect(provider.summary.value.allSkipped, isTrue);
  });

  test('复制日志归一化个人目录并脱敏', () async {
    await buildProvider(homeDirectories: const ['/home/alice']);
    final entries = [
      DiagnosticLogEntry(
        time: DateTime(2026, 11, 23, 10),
        level: 'INFO',
        logger: 'molia.test',
        message: 'read /home/alice/Music/song.mp3 Cookie: SESSDATA=raw-secret',
      ),
    ];
    expect(await provider.copyLogEntries(entries), isTrue);
    expect(copied.single, contains('~/Music/song.mp3'));
    expect(copied.single, isNot(contains('/home/alice/')));
    expect(copied.single, isNot(contains('SESSDATA=raw-secret')));
  });

  test('日志只在请求时读取，刷新会重新读盘', () async {
    await buildProvider();
    final file = File('${logDir.path}/molia.log');
    await file.writeAsString(
      '2026-11-23 10:00:00.000 INFO     molia.test: first\n',
    );
    expect(provider.logsState.value.status, DiagnosticsLogsStatus.idle);
    expect(await provider.logDirectoryPath(), logDir.path);

    await provider.loadLogs();
    expect(provider.logsState.value.status, DiagnosticsLogsStatus.ready);
    expect(provider.logsState.value.entries.single.message, 'first');

    await file.writeAsString(
      '2026-11-23 10:00:00.000 INFO     molia.test: first\n'
      '2026-11-23 10:00:01.000 WARNING  molia.test: second\n',
    );
    await provider.loadLogs();
    expect(provider.logsState.value.entries, hasLength(1));
    await provider.refreshLogs();
    expect(provider.logsState.value.entries, hasLength(2));
  });

  test('日志读取途中 dispose provider 不写已释放状态', () async {
    final service = DiagnosticsService(
      failures: FailureRingBuffer(),
      metrics: ResolveMetrics(),
    );
    final reader = _GatedLogReader();
    final provider = DiagnosticsProvider(
      service: service,
      builder: _RecordingBuilder(),
      saveAs: FakeSaveAs(),
      logReader: reader,
      copyText: (_) async {},
    );
    final loading = provider.loadLogs();
    await reader.started.future;
    provider.dispose();
    reader.release.complete();
    await expectLater(loading, completes);
    await service.dispose();
  });

  test('报告构建途中 dispose provider 不写已释放状态', () async {
    final service = DiagnosticsService(
      failures: FailureRingBuffer(),
      metrics: ResolveMetrics(),
    );
    final builder = _GatedBuilder();
    final provider = DiagnosticsProvider(
      service: service,
      builder: builder,
      saveAs: FakeSaveAs(),
      copyText: (_) async {},
    );
    final copying = provider.copyReport();
    await builder.started.future;
    provider.dispose();
    builder.release.complete();
    await expectLater(copying, completes);
    await service.dispose();
  });

  test('重启音源引擎转发到注入动作', () async {
    var calls = 0;
    await buildProvider(
      restartEngine: () async {
        calls++;
        return true;
      },
    );
    expect(await provider.restartSourceEngine(), isTrue);
    expect(calls, 1);
  });
}

DiagnosticSessionInfo _abnormalSession() => DiagnosticSessionInfo(
  startedAt: DateTime(2026, 11, 23, 10),
  previousExitAt: DateTime(2026, 11, 22, 22),
  previousAbnormalExit: true,
);

class _FakeSession extends DiagnosticSessionTracker {
  _FakeSession(this._info);

  final DiagnosticSessionInfo? _info;

  @override
  DiagnosticSessionInfo? get info => _info;

  @override
  Future<DiagnosticSessionInfo> start() async => _info!;
}

class _DeferredCheck implements DiagnosticCheck {
  final Completer<void> _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  DiagnosticCheckId get key => DiagnosticCheckId.appVersion;

  @override
  DiagnosticCheckGroup get group => DiagnosticCheckGroup.app;

  @override
  bool get requiresNetwork => false;

  @override
  Future<void> run(DiagnosticCheckContext context) async {
    await _gate.future;
    context.addResult(
      DiagnosticCheckResult(
        id: key,
        group: group,
        status: DiagnosticCheckStatus.ok,
        at: context.now(),
        stableValue: '1.0.0',
      ),
    );
  }
}

class _RecordingBuilder implements DiagnosticsBundleBuilder {
  int? textMaxBytes;
  int? bytesMaxBytes;

  @override
  Future<Uint8List> buildBytes({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
    int maxBytes = defaultDiagnosticsBundleMaxBytes,
  }) async {
    bytesMaxBytes = maxBytes;
    return Uint8List.fromList(utf8.encode('diagnostics bytes'));
  }

  @override
  Future<String> buildText({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
    int maxBytes = defaultDiagnosticsBundleMaxBytes,
  }) async {
    textMaxBytes = maxBytes;
    return 'diagnostics text';
  }

  @override
  String suggestedFileName([DateTime? at]) => 'molia_diagnostics_test.txt';
}

class _SkippedCheck implements DiagnosticCheck {
  @override
  DiagnosticCheckId get key => DiagnosticCheckId.databaseSchema;

  @override
  DiagnosticCheckGroup get group => DiagnosticCheckGroup.storage;

  @override
  bool get requiresNetwork => true;

  @override
  Future<void> run(DiagnosticCheckContext context) async {
    context.addResult(
      DiagnosticCheckResult(
        id: key,
        group: group,
        status: DiagnosticCheckStatus.skipped,
        at: context.now(),
        stableValue: 'unknown',
      ),
    );
  }
}

class _GatedLogReader extends LogTailReader {
  _GatedLogReader()
    : super(directory: () async => Directory('/tmp/molia-gated-logs'));

  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<List<DiagnosticLogEntry>> read() async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return const [];
  }
}

class _GatedBuilder implements DiagnosticsBundleBuilder {
  final started = Completer<void>();
  final release = Completer<void>();

  Future<void> _wait() async {
    if (!started.isCompleted) started.complete();
    await release.future;
  }

  @override
  Future<Uint8List> buildBytes({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
    int maxBytes = defaultDiagnosticsBundleMaxBytes,
  }) async {
    await _wait();
    return Uint8List.fromList(utf8.encode('diagnostics bytes'));
  }

  @override
  Future<String> buildText({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
    int maxBytes = defaultDiagnosticsBundleMaxBytes,
  }) async {
    await _wait();
    return 'diagnostics text';
  }

  @override
  String suggestedFileName([DateTime? at]) => 'molia_diagnostics_test.txt';
}
