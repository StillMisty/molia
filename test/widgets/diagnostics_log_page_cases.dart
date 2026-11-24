import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/diagnostics.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/diagnostics_log_page.dart';
import 'package:molia/providers/diagnostics_provider.dart';
import 'package:molia/services/diagnostics/diagnostics_bundle.dart';
import 'package:molia/services/diagnostics/diagnostics_export.dart';
import 'package:molia/services/diagnostics/diagnostics_service.dart';
import 'package:molia/services/diagnostics/failure_ring_buffer.dart';
import 'package:molia/services/diagnostics/log_tail_reader.dart';
import 'package:molia/services/diagnostics/resolve_metrics.dart';
import 'package:molia/services/notification_service.dart';

import '../support/fake_save_as.dart';
import '../support/notification_recorder.dart';
import '../support/provider_test_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('加载日志并按级别与关键词筛选', (tester) async {
    final harness = await _LogHarness.create(entries: _entries);
    addTearDown(harness.dispose);
    await _pumpLogPage(tester, harness);

    expect(find.text('first info'), findsOneWidget);
    expect(find.textContaining('cache miss'), findsOneWidget);
    expect(find.textContaining('4 条'), findsOneWidget);

    await tester.tap(find.text('警告以上'));
    await _settle(tester);
    expect(find.text('first info'), findsNothing);
    expect(find.textContaining('cache miss'), findsOneWidget);
    expect(find.text('cache failed'), findsOneWidget);
    expect(find.textContaining('2 条'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('diagnosticsLogSearch')),
      'failed',
    );
    await _settle(tester);
    expect(find.textContaining('cache miss'), findsNothing);
    expect(find.text('cache failed'), findsOneWidget);
    expect(find.textContaining('1 条'), findsOneWidget);
  });

  testWidgets('复制当前筛选结果', (tester) async {
    final harness = await _LogHarness.create(
      entries: _entries.take(3).toList(),
      homeDirectories: const ['/home/alice'],
    );
    addTearDown(harness.dispose);
    await _pumpLogPage(tester, harness);

    await tester.tap(find.text('警告以上'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('diagnosticsLogCopy')));
    await _settle(tester);

    expect(harness.copied.single, contains('cache miss'));
    expect(harness.copied.single, contains('cache failed'));
    expect(harness.copied.single, isNot(contains('first info')));
    expect(harness.copied.single, contains('~/Music/a.mp3'));
    expect(harness.copied.single, isNot(contains('/home/alice/')));
    expect(harness.copied.single, isNot(contains('SESSDATA=secret')));
    expect(harness.notifications.last, '已复制 2 条日志');
  });

  testWidgets('没有日志时显示空态', (tester) async {
    final harness = await _LogHarness.create();
    addTearDown(harness.dispose);
    await _pumpLogPage(tester, harness);
    expect(find.text('还没有日志'), findsOneWidget);
    expect(find.byKey(const Key('diagnosticsLogCopy')), findsOneWidget);
  });

  testWidgets('日志目录不可用显示不可用态', (tester) async {
    final harness = await _LogHarness.create(unavailable: true);
    addTearDown(harness.dispose);
    await _pumpLogPage(tester, harness);
    expect(find.text('日志不可用'), findsOneWidget);
    expect(find.text('还没有日志'), findsNothing);
  });

  testWidgets('360 / 640 宽度不出现布局溢出', (tester) async {
    final harness = await _LogHarness.create(entries: _entries);
    addTearDown(harness.dispose);
    for (final size in const [Size(360, 800), Size(640, 900)]) {
      await _pumpLogPage(tester, harness, size: size);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
      await _settle(tester);
      expect(tester.takeException(), isNull, reason: '宽度 ${size.width}');
    }
  });
}

final List<DiagnosticLogEntry> _entries = [
  _entry(0, 'INFO', 'first info'),
  _entry(
    1,
    'WARNING',
    'cache miss /home/alice/Music/a.mp3 Cookie: SESSDATA=secret',
  ),
  _entry(2, 'SEVERE', 'cache failed'),
  _entry(3, 'FINE', 'detail line'),
];

DiagnosticLogEntry _entry(int second, String level, String message) =>
    DiagnosticLogEntry(
      time: DateTime(2026, 11, 23, 10, 0, second),
      level: level,
      logger: 'molia.test',
      message: message,
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pumpLogPage(
  WidgetTester tester,
  _LogHarness harness, {
  Size size = const Size(1100, 1400),
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final scope = ProviderTestScope();
  scope.put<DiagnosticsProvider>(harness.provider);
  scope.put<NotificationService>(harness.notifications);
  await tester.pumpWidget(
    scope.wrap(
      M3EMaterialApp(
        data: M3EThemeData.fromMaterial(ThemeData.light()),
        theme: ThemeData.light(),
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        home: const DiagnosticsLogPage(),
      ),
    ),
  );
  await _settle(tester);
}

class _LogHarness {
  _LogHarness({
    required this.service,
    required this.provider,
    required this.copied,
    required this.notifications,
  });

  final DiagnosticsService service;
  final DiagnosticsProvider provider;
  final List<String> copied;
  final RecordingNotificationService notifications;

  static Future<_LogHarness> create({
    List<DiagnosticLogEntry> entries = const [],
    bool unavailable = false,
    List<String>? homeDirectories,
  }) async {
    final service = DiagnosticsService(
      failures: FailureRingBuffer(),
      metrics: ResolveMetrics(),
    );
    final copied = <String>[];
    final provider = DiagnosticsProvider(
      service: service,
      builder: _FakeBuilder(),
      saveAs: FakeSaveAs(),
      logReader: _FakeLogReader(entries: entries, unavailable: unavailable),
      copyText: (text) async => copied.add(text),
      writeTempFile: (name, bytes) async => '/tmp/$name',
      deleteTempFile: (_) async {},
      homeDirectories: homeDirectories,
    );
    return _LogHarness(
      service: service,
      provider: provider,
      copied: copied,
      notifications: RecordingNotificationService(),
    );
  }

  Future<void> dispose() async {
    provider.dispose();
    await service.dispose();
  }
}

class _FakeLogReader extends LogTailReader {
  _FakeLogReader({required this.entries, required this.unavailable})
    : super(
        directory: () async =>
            unavailable ? null : Directory('/tmp/molia-diagnostics-test'),
      );

  final List<DiagnosticLogEntry> entries;
  final bool unavailable;

  @override
  Future<List<DiagnosticLogEntry>> read() async => entries;
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
