import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:molia/pages/play_statistics_page.dart';
import 'package:molia/pages/statistics/play_statistics_page.dart'
    show playStatisticsPosterFileName;
import 'package:molia/providers/app_providers.dart';
import 'package:molia/providers/play_statistics_provider.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/services/save_as.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_save_as.dart';
import '../support/memory_database.dart';
import '../support/notification_recorder.dart';
import '../support/sync_test_support.dart';
import '../support/provider_test_scope.dart';
import '../support/settings_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MoliaDatabase db;
  late PlayStatisticsRepository repository;
  late PlayStatisticsProvider provider;
  late ProviderTestScope providerScope;
  late FakeSaveAs saveAs;
  late RecordingNotificationService notifications;
  late List<String> sharedPaths;
  late List<int> sharedSizes;
  late List<String> sharedTexts;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    attachStaticSettingsForTest(testSettingsRegistry());
    db = openMemoryDatabase();
    repository = PlayStatisticsRepository(
      databaseProvider: () => db,
      statisticsSync: testStatisticsSyncStore(() => db),
    );
    providerScope = ProviderTestScope(
      overrides: [
        playStatisticsRepositoryProvider.overrideWithValue(repository),
      ],
    );
    provider = providerScope.container.read(
      playStatisticsPageProvider.notifier,
    );
    saveAs = FakeSaveAs();
    notifications = RecordingNotificationService();
    sharedPaths = [];
    sharedSizes = [];
    sharedTexts = [];

    final now = DateTime.now().subtract(const Duration(days: 1));
    await insertPlayEvent(
      db,
      sourceKey: 'other',
      songId: 's1',
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      durationMs: 200000,
      startedAt: now.millisecondsSinceEpoch,
      endedAt: now.millisecondsSinceEpoch + 200000,
      listenedMs: 200000,
      maxPositionMs: 200000,
      endReason: 'completed',
    );
    await insertPlayEvent(
      db,
      sourceKey: 'other',
      songId: 's2',
      title: '十年',
      artist: '陈奕迅',
      durationMs: 180000,
      startedAt: now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
      endedAt:
          now.add(const Duration(minutes: 5)).millisecondsSinceEpoch + 180000,
      listenedMs: 180000,
      maxPositionMs: 180000,
      endReason: 'completed',
    );
  });

  tearDown(() async {
    await repository.dispose();
    await db.close();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    ProviderTestScope? withProviderScope,
  }) async {
    final scope = withProviderScope ?? providerScope;
    scope.put<SaveAs>(saveAs);
    scope.put<NotificationService>(notifications);
    await tester.pumpWidget(
      scope.wrap(
        M3EMaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          data: M3EThemeData.fromMaterial(ThemeData.light()),
          theme: ThemeData.light(),
          home: PlayStatisticsPage(
            sharePoster: (path, text) async {
              sharedPaths.add(path);
              sharedTexts.add(text);
              final file = File(path);
              sharedSizes.add(file.existsSync() ? file.lengthSync() : -1);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 海报渲染 / 写临时文件走真实异步：交替让出真实时间与刷新微任务。
  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> openShareSheet(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.ios_share_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await waitFor(
      tester,
      () =>
          find.byKey(const Key('posterShareAction')).evaluate().isNotEmpty ||
          find.text('还没有可以做成图片的记录').evaluate().isNotEmpty,
    );
  }

  Future<void> openOverflow(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
  }

  testWidgets('分享弹层：预览 + 分享 / 保存，导出数据不在里面', (tester) async {
    await pumpPage(tester);
    expect(provider.snapshot, isNotNull);
    expect(provider.isEmpty, isFalse);
    await openShareSheet(tester);
    expect(find.byKey(const Key('posterSharePreview')), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    expect(find.text('保存图片'), findsOneWidget);
    expect(find.text('导出数据'), findsNothing);
  });

  testWidgets('没有数据时分享弹层给出友好空态', (tester) async {
    await repository.clearAll();
    await pumpPage(tester);
    expect(provider.isEmpty, isTrue);

    await openShareSheet(tester);
    expect(find.text('还没有可以做成图片的记录'), findsOneWidget);
    expect(find.byKey(const Key('posterShareAction')), findsNothing);
    expect(sharedPaths, isEmpty);
  });

  testWidgets('分享图片经临时文件交给系统分享', (tester) async {
    await pumpPage(tester);
    await openShareSheet(tester);
    await tester.tap(find.byKey(const Key('posterShareAction')));
    await waitFor(
      tester,
      () => sharedPaths.isNotEmpty && !File(sharedPaths.single).existsSync(),
    );

    expect(notifications.messages, isEmpty);
    expect(sharedPaths, hasLength(1));
    expect(sharedTexts.single, '听歌记录');
    expect(sharedPaths.single, contains('molia_poster_'));
    expect(sharedSizes.single, greaterThan(0));
    expect(File(sharedPaths.single).existsSync(), isFalse, reason: '临时文件用完即删');
    expect(notifications.isEmpty, isTrue);
  });

  testWidgets('保存图片写入海报目录', (tester) async {
    await pumpPage(tester);
    await openShareSheet(tester);
    final saveAction = find.byKey(const Key('posterSaveImageAction'));
    await tester.ensureVisible(saveAction);
    await tester.tap(saveAction);
    await waitFor(tester, () => saveAs.saves.isNotEmpty);

    expect(saveAs.saves, hasLength(1));
    final call = saveAs.saves.single;
    expect(call.relativeDir, saveAsPostersDirName);
    expect(call.mimeType, 'image/png');
    expect(call.fileName, startsWith('molia_listening_stats_month_'));
    expect(call.bytes, isNotEmpty);
    expect(notifications.last, contains('posters/'));
  });

  test('海报文件名时间戳只来自统计窗口', () {
    expect(
      playStatisticsPosterFileName(
        DateTime(2030, 12, 31, 23, 59, 59),
        PlayStatisticsRange.month,
      ),
      'molia_listening_stats_month_2030-12-31T23-59-59.000.png',
    );
    expect(
      playStatisticsPosterFileName(null, PlayStatisticsRange.week),
      'molia_listening_stats_week.png',
      reason: '没有已接受窗口时不退回墙钟',
    );
  });

  testWidgets('导出文件名与载荷时间戳取统计窗口的 now', (tester) async {
    final fixed = DateTime(2030, 12, 31, 23, 59, 59);
    final scopedScope = ProviderTestScope(
      overrides: [
        playStatisticsRepositoryProvider.overrideWithValue(repository),
        playStatisticsClockProvider.overrideWithValue(() => fixed),
      ],
    );
    final scoped = scopedScope.container.read(
      playStatisticsPageProvider.notifier,
    );

    await pumpPage(tester, withProviderScope: scopedScope);
    expect(scoped.window!.now, fixed);
    await openOverflow(tester);
    await tester.tap(find.text('导出数据'));
    await waitFor(tester, () => saveAs.saves.isNotEmpty);

    final call = saveAs.saves.single;
    expect(call.fileName, 'molia_listening_2030-12-31T23-59-59.000.json');
    final payload = jsonDecode(utf8.decode(call.bytes)) as Map<String, dynamic>;
    expect(payload['exportedAt'], '2030-12-31T23:59:59.000');
  });

  testWidgets('导出数据在页面 ⋮ 里，仍写入 exports 目录', (tester) async {
    await pumpPage(tester);
    await openOverflow(tester);
    expect(find.text('导出数据'), findsOneWidget);
    expect(find.text('清空统计'), findsOneWidget);
    await tester.tap(find.text('导出数据'));
    await waitFor(tester, () => saveAs.saves.isNotEmpty);

    expect(saveAs.saves, hasLength(1));
    final call = saveAs.saves.single;
    expect(call.relativeDir, saveAsExportsDirName);
    expect(call.mimeType, 'application/json');
    final payload = jsonDecode(utf8.decode(call.bytes)) as Map<String, dynamic>;
    expect(payload, isNotEmpty);
  });
}
