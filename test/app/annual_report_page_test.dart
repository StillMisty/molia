import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/annual_report_page.dart';
import 'package:molia/providers/annual_report_provider.dart';
import 'package:molia/services/covers/custom_cover_store.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/services/save_as.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_save_as.dart';
import '../support/memory_database.dart';
import '../support/notification_recorder.dart';
import '../support/sync_test_support.dart';

/// 年度报告页：单页滚动、一个分享主操作、空年份隐藏行动。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MoliaDatabase db;
  late PlayStatisticsRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = openMemoryDatabase();
    repository = PlayStatisticsRepository(
      databaseProvider: () => db,
      statisticsSync: testStatisticsSyncStore(() => db),
    );
  });

  tearDown(() async {
    await repository.dispose();
    await db.close();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    required List<int> years,
    required int featuredYear,
    FakeSaveAs? saveAs,
    RecordingNotificationService? notifications,
  }) async {
    await tester.pumpWidget(
      M3EMaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        data: M3EThemeData.fromMaterial(ThemeData.light()),
        theme: ThemeData.light(),
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider(
              create: (_) => AnnualReportProvider(
                repository: repository,
                clock: () => DateTime(2026, 11, 14),
              ),
            ),
            Provider<CustomCoverStore>.value(value: CustomCoverStore()),
            if (saveAs != null) Provider<SaveAs>.value(value: saveAs),
            if (notifications != null)
              Provider<NotificationService?>.value(value: notifications),
          ],
          child: AnnualReportPage(years: years, featuredYear: featuredYear),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('有数据：年份、分享主操作与存歌单入口', (tester) async {
    final start = DateTime(2026, 3, 1, 12);
    await insertPlayEvent(
      db,
      songId: 's1',
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      startedAt: start.millisecondsSinceEpoch,
      endedAt: start.millisecondsSinceEpoch + 120000,
      listenedMs: 120000,
      maxPositionMs: 120000,
      endReason: 'completed',
    );
    await pumpPage(tester, years: [2026], featuredYear: 2026);
    expect(find.text('2026'), findsWidgets);
    expect(find.text('分享海报'), findsOneWidget);
    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('截至今天'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('存成歌单'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('存成歌单'), findsOneWidget);
    expect(find.textContaining('至 截至今天'), findsNothing);
    expect(find.textContaining('数据范围：'), findsOneWidget);
  });

  testWidgets('保存图片写入海报目录，分享主操作仍在', (tester) async {
    final start = DateTime(2026, 4, 1, 12);
    await insertPlayEvent(
      db,
      sourceKey: 'other',
      songId: 'save1',
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      startedAt: start.millisecondsSinceEpoch,
      endedAt: start.millisecondsSinceEpoch + 120000,
      listenedMs: 120000,
      maxPositionMs: 120000,
      endReason: 'completed',
    );
    final saveAs = FakeSaveAs();
    final notifications = RecordingNotificationService();
    await pumpPage(
      tester,
      years: [2026],
      featuredYear: 2026,
      saveAs: saveAs,
      notifications: notifications,
    );

    expect(find.text('分享海报'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存图片'));
    // 保存中会显示不确定进度条：不能 pumpAndSettle，交替让出真实异步直到落盘。
    for (var i = 0; i < 100 && saveAs.saves.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(saveAs.saves, hasLength(1));
    final call = saveAs.saves.single;
    expect(call.relativeDir, saveAsPostersDirName);
    expect(call.mimeType, 'image/png');
    expect(call.fileName, 'molia_annual_2026.png');
    expect(call.bytes, isNotEmpty);
    expect(notifications.last, contains('posters/'));
  });

  testWidgets('空年份：诚实空态，隐藏分享与歌单', (tester) async {
    await pumpPage(tester, years: [2020], featuredYear: 2020);
    expect(find.text('这一年还没有听歌记录'), findsOneWidget);
    expect(find.text('分享海报'), findsNothing);
    expect(find.text('存成歌单'), findsNothing);
  });
}
