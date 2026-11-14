import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/play_statistics_page.dart';
import 'package:molia/providers/play_statistics_provider.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/services/save_as.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_save_as.dart';
import '../support/memory_database.dart';
import '../support/notification_recorder.dart';
import '../support/sync_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MoliaDatabase db;
  late PlayStatisticsRepository repository;
  late PlayStatisticsProvider provider;
  late FakeSaveAs saveAs;
  late RecordingNotificationService notifications;
  late List<String> sharedPaths;
  late List<int> sharedSizes;
  late List<String> sharedTexts;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = openMemoryDatabase();
    repository = PlayStatisticsRepository(
      databaseProvider: () => db,
      statisticsSync: testStatisticsSyncStore(() => db),
    );
    provider = PlayStatisticsProvider(repository: repository);
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
    provider.dispose();
    await repository.dispose();
    await db.close();
  });

  Future<void> pumpPage(WidgetTester tester) async {
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
            ChangeNotifierProvider<PlayStatisticsProvider>.value(
              value: provider,
            ),
            Provider<SaveAs>.value(value: saveAs),
            Provider<NotificationService?>.value(value: notifications),
          ],
          child: PlayStatisticsPage(
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

  Future<void> openShareMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.ios_share_rounded));
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

  testWidgets('分享菜单提供分享图片 / 保存图片 / 导出 JSON', (tester) async {
    await pumpPage(tester);
    expect(provider.snapshot, isNotNull);
    expect(provider.isEmpty, isFalse);
    await openShareMenu(tester);
    expect(find.text('分享图片'), findsOneWidget);
    expect(find.text('保存图片'), findsOneWidget);
    expect(find.text('导出听歌数据'), findsOneWidget);
  });

  testWidgets('没有数据时分享图片给出友好提示', (tester) async {
    await repository.clearAll();
    await pumpPage(tester);
    expect(provider.isEmpty, isTrue);

    await openShareMenu(tester);
    await tester.tap(find.widgetWithText(M3EListItem, '分享图片'));
    await tester.pumpAndSettle();

    expect(sharedPaths, isEmpty);
    expect(notifications.last, '还没有可以做成图片的记录');
  });

  testWidgets('分享图片经临时文件交给系统分享', (tester) async {
    await pumpPage(tester);
    await openShareMenu(tester);
    await tester.tap(find.widgetWithText(M3EListItem, '分享图片'));
    await waitFor(
      tester,
      () => sharedPaths.isNotEmpty && !File(sharedPaths.single).existsSync(),
    );

    expect(find.text('分享图片'), findsNothing);
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
    await openShareMenu(tester);
    await tester.tap(find.text('保存图片'));
    await waitFor(tester, () => saveAs.saves.isNotEmpty);

    expect(saveAs.saves, hasLength(1));
    final call = saveAs.saves.single;
    expect(call.relativeDir, saveAsPostersDirName);
    expect(call.mimeType, 'image/png');
    expect(call.fileName, startsWith('molia_listening_stats_month_'));
    expect(call.bytes, isNotEmpty);
    expect(notifications.last, contains('posters/'));
  });

  testWidgets('导出 JSON 仍写入 exports 目录', (tester) async {
    await pumpPage(tester);
    await openShareMenu(tester);
    await tester.tap(find.text('导出听歌数据'));
    await waitFor(tester, () => saveAs.saves.isNotEmpty);

    expect(saveAs.saves, hasLength(1));
    final call = saveAs.saves.single;
    expect(call.relativeDir, saveAsExportsDirName);
    expect(call.mimeType, 'application/json');
    final payload = jsonDecode(utf8.decode(call.bytes)) as Map<String, dynamic>;
    expect(payload, isNotEmpty);
  });
}
