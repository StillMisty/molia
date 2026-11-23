import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/diagnostics.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/diagnostics_page.dart';
import 'package:molia/providers/diagnostics_provider.dart';
import 'package:molia/services/diagnostics/diagnostics_bundle.dart';
import 'package:molia/services/diagnostics/diagnostics_export.dart';
import 'package:molia/services/diagnostics/diagnostics_runner.dart';
import 'package:molia/services/diagnostics/diagnostics_service.dart';
import 'package:molia/services/diagnostics/failure_ring_buffer.dart';
import 'package:molia/services/diagnostics/log_tail_reader.dart';
import 'package:molia/services/diagnostics/resolve_metrics.dart';
import 'package:molia/services/notification_service.dart';

import '../support/fake_save_as.dart';
import '../support/notification_recorder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('打开页面不自动检查，只有一个主按钮', (tester) async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await _pumpPage(tester, harness);

    expect(find.text('还没有检查'), findsOneWidget);
    expect(find.byKey(const Key('diagnosticsPrimaryAction')), findsOneWidget);
    expect(find.byType(M3EButton), findsOneWidget, reason: '页面只留一个主按钮');
    expect(
      find.byKey(const Key('diagnosticsCopyReportAction')),
      findsOneWidget,
    );
    expect(harness.runner.runs, isEmpty);
    expect(harness.runner.current, isNull);
  });

  testWidgets('检查中显示运行态，完成后给出正常结论', (tester) async {
    final check = _DeferredCheck();
    final harness = await _Harness.create(checks: [check]);
    addTearDown(harness.dispose);
    await _pumpPage(tester, harness);

    await tester.tap(find.byKey(const Key('diagnosticsPrimaryAction')));
    await tester.pump();
    await tester.pump();
    expect(find.text('正在检查…'), findsWidgets);

    check.release();
    await _finishChecks(tester, harness);
    await tester.pumpAndSettle();
    expect(find.text('一切正常'), findsOneWidget);
    expect(find.textContaining('最近检查'), findsWidgets);
  });

  testWidgets('失败优先于警告出现在摘要', (tester) async {
    final harness = await _Harness.create(
      checks: [
        _ResultCheck(
          key: DiagnosticCheckId.sourceEngine,
          group: DiagnosticCheckGroup.sources,
          status: DiagnosticCheckStatus.failed,
          failure: const HealthFailure(
            kind: FailureKind.scriptError,
            retryable: true,
          ),
        ),
        _ResultCheck(
          key: DiagnosticCheckId.databaseSchema,
          group: DiagnosticCheckGroup.storage,
          status: DiagnosticCheckStatus.warning,
          stableValue: '12/14',
        ),
      ],
    );
    addTearDown(harness.dispose);
    await _pumpPage(tester, harness);

    await tester.tap(find.byKey(const Key('diagnosticsPrimaryAction')));
    await _finishChecks(tester, harness);
    await tester.pumpAndSettle();
    expect(find.text('1 项需要处理'), findsOneWidget);

    final warningOnly = await _Harness.create(
      checks: [
        _ResultCheck(
          key: DiagnosticCheckId.databaseSchema,
          group: DiagnosticCheckGroup.storage,
          status: DiagnosticCheckStatus.warning,
          stableValue: '12/14',
        ),
      ],
    );
    addTearDown(warningOnly.dispose);
    await _pumpPage(tester, warningOnly);
    await tester.tap(find.byKey(const Key('diagnosticsPrimaryAction')));
    await _finishChecks(tester, warningOnly);
    await tester.pumpAndSettle();
    expect(find.text('1 项需要注意'), findsOneWidget);
  });

  testWidgets('渠道三步合并一行，非渠道检查按分组展示', (tester) async {
    final harness = await _Harness.create(
      checks: [
        _ChannelCheck(),
        _ResultCheck(
          key: DiagnosticCheckId.appVersion,
          group: DiagnosticCheckGroup.app,
          status: DiagnosticCheckStatus.ok,
          stableValue: '9.9.9',
        ),
        _ResultCheck(
          key: DiagnosticCheckId.databaseSchema,
          group: DiagnosticCheckGroup.storage,
          status: DiagnosticCheckStatus.warning,
          stableValue: '12/14',
        ),
      ],
    );
    addTearDown(harness.dispose);
    await _pumpPage(tester, harness);

    await tester.tap(find.byKey(const Key('diagnosticsPrimaryAction')));
    await _finishChecks(tester, harness);
    await tester.pumpAndSettle();

    final channelRow = find.byKey(const ValueKey('diagnosticsCheckRow-kw'));
    await tester.scrollUntilVisible(
      channelRow,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(channelRow, findsOneWidget);
    expect(find.text('酷我 · 正常'), findsOneWidget);
    expect(find.textContaining('搜索：正常，10 毫秒'), findsOneWidget);
    expect(find.textContaining('播放链接：正常，20 毫秒'), findsOneWidget);
    expect(find.textContaining('播放流：正常，30 毫秒'), findsOneWidget);
    expect(find.textContaining('共 60 毫秒'), findsOneWidget);

    final databaseRow = find.byKey(
      const ValueKey('diagnosticsCheckRow-databaseSchema'),
    );
    await tester.scrollUntilVisible(
      databaseRow,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('数据库结构 · 需要注意'), findsOneWidget);
    expect(find.text('存储'), findsOneWidget);
  });

  testWidgets('检查详情展示三步并提供复制与重试动作', (tester) async {
    final harness = await _Harness.create(checks: [_ChannelCheck()]);
    addTearDown(harness.dispose);
    await _pumpPage(tester, harness);
    await tester.tap(find.byKey(const Key('diagnosticsPrimaryAction')));
    await _finishChecks(tester, harness);
    await tester.pumpAndSettle();

    final channelRow = find.byKey(const ValueKey('diagnosticsCheckRow-kw'));
    await tester.scrollUntilVisible(
      channelRow,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(channelRow);
    await tester.pumpAndSettle();

    expect(find.text('检查详情'), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('播放链接'), findsOneWidget);
    expect(find.text('播放流'), findsOneWidget);
    expect(find.byKey(const Key('diagnosticsCheckRetry')), findsOneWidget);
    expect(
      find.byKey(const Key('diagnosticsCheckRestartEngine')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('diagnosticsCheckCopyDetails')));
    await tester.pumpAndSettle();
    expect(harness.copied.last, contains('酷我'));
    expect(harness.notifications.last, '已复制到剪贴板');
  });

  testWidgets('最近问题按渠道与原因分组，详情可复制', (tester) async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    for (var i = 0; i < 2; i++) {
      harness.service.recordFailure(
        failure: const SourceFailure(kind: FailureKind.network, message: ''),
        channelKey: 'kw',
        channelDisplayName: '酷我',
      );
    }
    await _pumpPage(tester, harness);

    final issueRow = find.byKey(
      const ValueKey('diagnosticsIssueRow-kw-network'),
    );
    await tester.scrollUntilVisible(
      issueRow,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('酷我 · 网络问题'), findsOneWidget);
    expect(find.textContaining('2 次'), findsOneWidget);

    await tester.tap(issueRow);
    await tester.pumpAndSettle();
    expect(find.text('问题详情'), findsOneWidget);
    expect(find.text('网络问题'), findsWidgets);
    expect(find.text('渠道'), findsOneWidget);

    await tester.tap(find.byKey(const Key('diagnosticsIssueCopyDetails')));
    await tester.pumpAndSettle();
    expect(harness.copied.last, contains('酷我'));
    expect(harness.copied.last, contains('网络问题'));
    expect(harness.notifications.last, '已复制到剪贴板');
  });

  testWidgets('报告复制、保存与分享走注入通道', (tester) async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await _pumpPage(tester, harness);

    await tester.tap(find.byKey(const Key('diagnosticsCopyReportAction')));
    await tester.pumpAndSettle();
    expect(harness.copied.single, 'diagnostics text');
    expect(harness.notifications.last, '报告已复制');

    final saveRow = find.byKey(const Key('diagnosticsSaveReport'));
    await tester.scrollUntilVisible(
      saveRow,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(saveRow);
    await tester.pumpAndSettle();
    expect(harness.saveAs.saves, hasLength(1));
    expect(harness.saveAs.saves.single.relativeDir, 'exports');
    expect(harness.notifications.last, isNotEmpty);

    final shareRow = find.byKey(const Key('diagnosticsShareReport'));
    await tester.scrollUntilVisible(
      shareRow,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(shareRow);
    await tester.pumpAndSettle();
    expect(harness.shared, hasLength(1));
    expect(harness.notifications.last, '报告已交给系统分享');
  });

  testWidgets('报告弹层先预览再复制', (tester) async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await _pumpPage(tester, harness);

    final previewRow = find.byKey(const Key('diagnosticsPreviewReport'));
    await tester.scrollUntilVisible(
      previewRow,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(previewRow);
    await tester.pumpAndSettle();
    expect(find.text('诊断报告预览'), findsOneWidget);
    expect(find.textContaining('diagnostics text'), findsOneWidget);

    await tester.tap(find.byKey(const Key('diagnosticsReportCopy')));
    await tester.pumpAndSettle();
    expect(harness.copied.last, 'diagnostics text');
  });

  testWidgets('360 / 640 宽度不出现布局溢出', (tester) async {
    for (final size in const [Size(360, 800), Size(640, 900)]) {
      final harness = await _Harness.create(
        checks: [
          _ChannelCheck(),
          _ResultCheck(
            key: DiagnosticCheckId.databaseSchema,
            group: DiagnosticCheckGroup.storage,
            status: DiagnosticCheckStatus.warning,
            stableValue: '12/14',
          ),
        ],
      );
      addTearDown(harness.dispose);
      await _pumpPage(tester, harness, size: size);
      await tester.tap(find.byKey(const Key('diagnosticsPrimaryAction')));
      await _finishChecks(tester, harness);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -4000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '宽度 ${size.width}');
    }
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  _Harness harness, {
  Size size = const Size(1100, 1400),
}) async {
  // 同一测试里换 provider 时先卸载旧页面，避免 State 继续读旧 provider。
  await tester.pumpWidget(const SizedBox.shrink());
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<DiagnosticsProvider>.value(
          value: harness.provider,
        ),
        Provider<NotificationService>.value(value: harness.notifications),
      ],
      child: M3EMaterialApp(
        data: M3EThemeData.fromMaterial(ThemeData.light()),
        theme: ThemeData.light(),
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        home: const DiagnosticsPage(),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _finishChecks(WidgetTester tester, _Harness harness) async {
  await tester.runAsync(() => harness.runner.idle);
  await tester.pump();
  await tester.pump();
}

class _Harness {
  _Harness({
    required this.service,
    required this.runner,
    required this.provider,
    required this.saveAs,
    required this.copied,
    required this.shared,
    required this.notifications,
  });

  final DiagnosticsService service;
  final DiagnosticsRunner runner;
  final DiagnosticsProvider provider;
  final FakeSaveAs saveAs;
  final List<String> copied;
  final List<String> shared;
  final RecordingNotificationService notifications;

  static Future<_Harness> create({
    List<DiagnosticCheck> checks = const [],
  }) async {
    final service = DiagnosticsService(
      failures: FailureRingBuffer(),
      metrics: ResolveMetrics(),
    );
    final runner = DiagnosticsRunner(checks: checks);
    service.attachRunner(runner);
    final copied = <String>[];
    final shared = <String>[];
    final saveAs = FakeSaveAs();
    final provider = DiagnosticsProvider(
      service: service,
      builder: _FakeBuilder(),
      saveAs: saveAs,
      appInfo: () async => const DiagnosticsAppInfo(
        version: '9.9.9',
        buildNumber: '42',
        platform: 'linux',
      ),
      logReader: _FakeLogReader(),
      copyText: (text) async => copied.add(text),
      shareFile: (path) async => shared.add(path),
      writeTempFile: (name, bytes) async => '/tmp/$name',
    );
    return _Harness(
      service: service,
      runner: runner,
      provider: provider,
      saveAs: saveAs,
      copied: copied,
      shared: shared,
      notifications: RecordingNotificationService(),
    );
  }

  Future<void> dispose() async {
    provider.dispose();
    await service.dispose();
  }
}

class _FakeBuilder implements DiagnosticsBundleBuilder {
  @override
  Future<Uint8List> buildBytes({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
    int maxBytes = defaultDiagnosticsBundleMaxBytes,
  }) async => Uint8List.fromList(utf8.encode('diagnostics text'));

  @override
  Future<String> buildText({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
    int maxBytes = defaultDiagnosticsBundleMaxBytes,
  }) async => 'diagnostics text';

  @override
  String suggestedFileName([DateTime? at]) => 'molia_diagnostics_test.txt';
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
        stableValue: '9.9.9',
      ),
    );
  }
}

class _ResultCheck implements DiagnosticCheck {
  _ResultCheck({
    required this.key,
    required this.group,
    required this.status,
    this.stableValue,
    this.failure,
  });

  @override
  final DiagnosticCheckId key;

  @override
  final DiagnosticCheckGroup group;

  final DiagnosticCheckStatus status;
  final String? stableValue;
  final HealthFailure? failure;

  @override
  bool get requiresNetwork => false;

  @override
  Future<void> run(DiagnosticCheckContext context) async {
    context.addResult(
      DiagnosticCheckResult(
        id: key,
        group: group,
        status: status,
        at: context.now(),
        stableValue: stableValue,
        failure: failure,
      ),
    );
  }
}

class _ChannelCheck implements DiagnosticCheck {
  @override
  DiagnosticCheckId get key => DiagnosticCheckId.channelSearch;

  @override
  DiagnosticCheckGroup get group => DiagnosticCheckGroup.sources;

  @override
  bool get requiresNetwork => false;

  @override
  Future<void> run(DiagnosticCheckContext context) async {
    final at = context.now();
    for (final (id, latency) in const [
      (DiagnosticCheckId.channelSearch, 10),
      (DiagnosticCheckId.channelResolve, 20),
      (DiagnosticCheckId.channelStream, 30),
    ]) {
      context.addResult(
        DiagnosticCheckResult(
          id: id,
          group: group,
          status: DiagnosticCheckStatus.ok,
          at: at,
          latencyMs: latency,
          channelKey: 'kw',
          channelDisplayName: '酷我',
        ),
      );
    }
  }
}

class _FakeLogReader extends LogTailReader {
  _FakeLogReader()
    : super(directory: () async => Directory('/tmp/molia-diagnostics-test'));

  @override
  Future<List<DiagnosticLogEntry>> read() async => const [];
}
