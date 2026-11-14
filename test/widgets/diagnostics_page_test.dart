import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/diagnostics_page.dart';
import 'package:molia/providers/diagnostics_provider.dart';
import 'package:molia/services/diagnostics/diagnostics_bundle.dart';
import 'package:molia/services/diagnostics/diagnostics_export.dart';
import 'package:molia/services/diagnostics/diagnostics_service.dart';
import 'package:molia/services/diagnostics/failure_ring_buffer.dart';
import 'package:molia/services/diagnostics/source_health_checker.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/services/save_as.dart';

import '../support/fake_save_as.dart';
import '../support/notification_recorder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DiagnosticsService service;
  late FakeSaveAs saveAs;
  late RecordingNotificationService notifications;
  late DiagnosticsProvider provider;

  setUp(() {
    service = DiagnosticsService(failures: FailureRingBuffer());
    service.attachHealth(
      SourceHealthChecker(
        probe: _FakeProbe(),
        config: const SourceHealthConfig(
          gap: Duration.zero,
          cooldown: Duration.zero,
        ),
        delay: (_) async {},
      ),
    );
    saveAs = FakeSaveAs();
    notifications = RecordingNotificationService();
    provider = DiagnosticsProvider(
      service: service,
      builder: _FakeBuilder(),
      saveAs: saveAs,
      appInfo: () async => const DiagnosticsAppInfo(
        version: '9.9.9',
        buildNumber: '42',
        platform: 'linux',
        osVersion: 'Linux 6',
      ),
    );
  });

  tearDown(() async {
    provider.dispose();
    await service.dispose();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DiagnosticsProvider>.value(value: provider),
          Provider<NotificationService>.value(value: notifications),
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
    await tester.pumpAndSettle();
  }

  test('包信息读取失败回退 unknown 并通知', () async {
    final fallback = DiagnosticsProvider(
      service: service,
      builder: _FakeBuilder(),
      saveAs: saveAs,
      appInfo: () async => throw StateError('package info unavailable'),
    );
    var notified = 0;
    fallback.addListener(() => notified++);
    fallback.ensureAppInfo();
    await pumpEventQueue();
    expect(fallback.appInfo, isNotNull);
    expect(fallback.appInfo!.version, 'unknown');
    expect(notified, greaterThan(0));
    fallback.dispose();
  });

  testWidgets('概览、空态、导出图标与唯一检查主操作', (tester) async {
    await pumpPage(tester);
    expect(find.text('问题排查'), findsWidgets);
    expect(find.textContaining('9.9.9'), findsOneWidget);
    expect(find.text('还没有记录到问题'), findsOneWidget);
    expect(find.text('还没有检查记录'), findsOneWidget);
    expect(
      find.byKey(const Key('diagnosticsExportButton')),
      findsOneWidget,
      reason: '导出收进顶栏图标',
    );
    expect(
      tester.widget(find.byKey(const Key('diagnosticsExportButton'))),
      isA<M3EIconButton>(),
    );
    expect(find.byKey(const Key('diagnosticsCheckButton')), findsOneWidget);
    expect(find.byType(M3EButton), findsOneWidget, reason: '页面只留一个主按钮');
  });

  testWidgets('最近失败只显示本地化原因，不显示原始 message', (tester) async {
    service.recordFailure(
      failure: const SourceFailure(
        kind: FailureKind.network,
        message: 'Cookie: SESSDATA=raw-secret',
      ),
      channelKey: 'kw',
      channelDisplayName: '酷我',
    );
    await pumpPage(tester);
    expect(find.textContaining('酷我'), findsOneWidget);
    expect(find.text('网络问题'), findsOneWidget);
    expect(find.textContaining('raw-secret'), findsNothing);
  });

  testWidgets('导出走 fake Save As，成功提示且不泄露种子文本', (tester) async {
    await pumpPage(tester);
    await tester.ensureVisible(
      find.byKey(const Key('diagnosticsExportButton')),
    );
    await tester.tap(find.byKey(const Key('diagnosticsExportButton')));
    await tester.pumpAndSettle();

    expect(saveAs.saves, hasLength(1));
    final call = saveAs.saves.single;
    expect(call.fileName, endsWith('.txt'));
    expect(call.mimeType, 'text/plain');
    expect(call.relativeDir, saveAsExportsDirName);
    expect(utf8.decode(call.bytes), isNot(contains('raw-secret')));
    expect(notifications.messages, isNotEmpty);
  });

  testWidgets('开始检查后显示紧凑的状态与延迟列表', (tester) async {
    await pumpPage(tester);
    await tester.ensureVisible(find.byKey(const Key('diagnosticsCheckButton')));
    await tester.tap(find.byKey(const Key('diagnosticsCheckButton')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('酷我'), findsOneWidget);
    expect(find.textContaining('正常'), findsWidgets);
    expect(find.textContaining('毫秒'), findsOneWidget);
  });
}

class _FakeBuilder implements DiagnosticsBundleBuilder {
  @override
  Future<Uint8List> buildBytes({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
  }) async => Uint8List.fromList(utf8.encode('diagnostics bundle'));

  @override
  Future<String> buildText({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
  }) async => 'diagnostics bundle';

  @override
  String suggestedFileName([DateTime? at]) => 'molia_diagnostics_test.txt';
}

class _FakeProbe implements SourceHealthProbe {
  @override
  List<SourceHealthTarget> get targets => const [
    SourceHealthTarget(key: 'kw', displayName: '酷我', canResolve: true),
  ];

  @override
  Future<void> resolve(SourceHealthTarget target, Track track) async {}

  @override
  Future<Track?> search(SourceHealthTarget target) async => Track(
    id: const TrackId('kw', '1'),
    title: 'Song',
    origin: TrackOrigin.builtin,
  );
}
