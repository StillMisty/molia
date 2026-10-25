import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/downloads/downloads_repository.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/download_settings_page.dart';
import 'package:molia/pages/downloads_manage_page.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/download/download_service.dart';
import 'package:molia/services/download/download_settings.dart';
import 'package:molia/services/save_as.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_download_notifications.dart';
import '../support/fake_download_storage.dart';
import '../support/fake_downloads_publisher.dart';
import '../support/fake_music_source.dart';
import '../support/fake_save_as.dart';
import '../support/fakes.dart';

/// 下载设置页 / 下载管理页 smoke：段落与开关接线（动作细节由服务测试覆盖）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DownloadSettings settings;
  late DownloadService downloads;
  late PlaybackProvider playback;
  late FakePlaybackBackend backend;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = DownloadSettings();
    await settings.init();
    downloads = DownloadService(
      catalog: CatalogService(registry: FakeSourceRegistry(const {})),
      repository: DownloadsRepository(
        databaseProvider: () => throw UnimplementedError(),
      ),
      storage: FakeDownloadStorage(),
      settings: settings,
      // Android 语义（发布器支持）：设置页 / 管理页显示公共目录条目。
      publisher: FakeDownloadsPublisher(),
      notifications: FakeDownloadNotifications(),
    );
    await downloads.init();
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
  });

  tearDown(() {
    playback.dispose();
    downloads.dispose();
    settings.dispose();
  });

  Future<void> pumpPage(
    WidgetTester tester,
    Widget page, {
    SaveAs? saveAs,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DownloadSettings>.value(value: settings),
          ChangeNotifierProvider<DownloadService>.value(value: downloads),
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          if (saveAs != null) Provider<SaveAs>.value(value: saveAs),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: page,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('下载设置页：保存位置 / 文件名格式 / 标签嵌入与下载目录', (tester) async {
    // widget 测试默认平台是 Android；这里显式跑桌面口径（自选目录）。
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await pumpPage(tester, const DownloadSettingsPage());

      expect(find.text('下载设置'), findsOneWidget);
      expect(find.text('保存位置'), findsOneWidget);
      expect(find.text('默认（系统「下载」目录）'), findsOneWidget);
      expect(find.text('文件名格式'), findsOneWidget);
      expect(find.text('{artist} - {title}'), findsOneWidget);
      expect(find.text('嵌入歌词与封面标签'), findsOneWidget);
      expect(find.text('下载目录'), findsOneWidget);
      // 发布器支持（Android）：公共目录发布开关可见，默认开。
      expect(
        find.byKey(const Key('downloadPublishPublicSwitch')),
        findsOneWidget,
      );
      expect(find.text('发布到公共下载目录'), findsOneWidget);
      // 通知支持（Android）：下载通知开关可见，默认开。
      expect(
        find.byKey(const Key('downloadNotificationsSwitch')),
        findsOneWidget,
      );
      expect(find.text('下载通知'), findsOneWidget);

      // 关闭标签嵌入：持久化。
      await tester.tap(find.byKey(const Key('downloadEmbedTagsSwitch')));
      await tester.pumpAndSettle();
      expect(settings.embedTags, isFalse);

      // 关闭公共目录发布：持久化。
      await tester.tap(find.byKey(const Key('downloadPublishPublicSwitch')));
      await tester.pumpAndSettle();
      expect(settings.publishToPublicDir, isFalse);

      // 关闭下载通知：持久化。
      await tester.tap(find.byKey(const Key('downloadNotificationsSwitch')));
      await tester.pumpAndSettle();
      expect(settings.notifications, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('下载设置页（Android）：显示播放副本与另存目录', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpPage(
        tester,
        const DownloadSettingsPage(),
        saveAs: FakeSaveAs(root: '/storage/emulated/0/Download/Molia'),
      );

      expect(find.text('系统「下载」› Molia'), findsWidgets);
      expect(find.text('播放副本'), findsOneWidget);
      expect(find.text('另存目录'), findsOneWidget);
      expect(
        find.byKey(const Key('downloadPublicLocationInfoItem')),
        findsOneWidget,
      );
      expect(find.text('/storage/emulated/0/Download/Molia'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('下载设置页：发布器不支持（非 Android）时隐藏公共目录开关', (tester) async {
    final nonAndroid = DownloadService(
      catalog: CatalogService(registry: FakeSourceRegistry(const {})),
      repository: DownloadsRepository(
        databaseProvider: () => throw UnimplementedError(),
      ),
      storage: FakeDownloadStorage(),
      settings: settings,
      publisher: FakeDownloadsPublisher(supported: false),
      notifications: FakeDownloadNotifications(supported: false),
    );
    await nonAndroid.init();
    addTearDown(nonAndroid.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DownloadSettings>.value(value: settings),
          ChangeNotifierProvider<DownloadService>.value(value: nonAndroid),
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: const DownloadSettingsPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('downloadPublishPublicSwitch')), findsNothing);
    expect(find.byKey(const Key('downloadNotificationsSwitch')), findsNothing);
  });

  testWidgets('下载设置页：文件名模板弹层实时预览并可保存', (tester) async {
    await pumpPage(tester, const DownloadSettingsPage());

    await tester.tap(find.byKey(const Key('downloadFilenameTemplateItem')));
    await tester.pumpAndSettle();
    expect(find.textContaining('预览'), findsOneWidget);

    await tester.enterText(find.byType(M3ETextField), '{title} - {artist}');
    await tester.pumpAndSettle();
    expect(find.textContaining('歌名 - 歌手'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(settings.filenameTemplate, '{title} - {artist}');
  });

  testWidgets('下载管理页：进行中 / 批量下载 / 文件维护段落齐全', (tester) async {
    await pumpPage(tester, const DownloadsManagePage());

    expect(find.text('下载管理'), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('没有进行中的下载'), findsOneWidget);
    expect(find.text('批量下载'), findsOneWidget);
    expect(find.byKey(const Key('downloadsBatchQueueItem')), findsOneWidget);
    expect(find.byKey(const Key('downloadsBatchPlaylistItem')), findsOneWidget);
    expect(find.text('文件维护'), findsOneWidget);
    expect(find.byKey(const Key('downloadsCleanupPartsItem')), findsOneWidget);
    expect(
      find.byKey(const Key('downloadsCleanupOrphansItem')),
      findsOneWidget,
    );
    // 发布器支持（Android）：补发布入口可见。
    expect(find.byKey(const Key('downloadsPublishPublicItem')), findsOneWidget);
    expect(find.text('补一份到公共目录'), findsOneWidget);
  });

  testWidgets('下载管理页：半成品清扫提示数量', (tester) async {
    final storage = FakeDownloadStorage();
    storage.files['/downloads/a.mp3.part'] = [1];
    final service = DownloadService(
      catalog: CatalogService(registry: FakeSourceRegistry(const {})),
      repository: DownloadsRepository(
        databaseProvider: () => throw UnimplementedError(),
      ),
      storage: storage,
      settings: settings,
    );
    await service.init();
    addTearDown(service.dispose);

    await pumpPage(tester, const DownloadsManagePage());
    // 页面用 context.read 的实例：替换为带半成品的服务。
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DownloadSettings>.value(value: settings),
          ChangeNotifierProvider<DownloadService>.value(value: service),
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: const DownloadsManagePage(),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('downloadsCleanupPartsItem')));
    await tester.pumpAndSettle();
    expect(find.text('已清理 1 个未完成文件'), findsOneWidget);
  });
}
