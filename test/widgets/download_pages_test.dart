import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/downloads/downloads_repository.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/download_settings_page.dart';
import 'package:molia/pages/downloads_manage_page.dart';
import 'package:molia/providers/library_provider.dart';
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
import '../support/fake_library_repository.dart';
import '../support/fake_music_source.dart';
import '../support/fake_save_as.dart';
import '../support/fakes.dart';

/// 只记录批量入队的下载服务（页面流程测试不触网 / 不落库）。
class _RecordingDownloadService extends DownloadService {
  _RecordingDownloadService()
    : super(
        catalog: CatalogService(registry: FakeSourceRegistry(const {})),
        repository: DownloadsRepository(
          databaseProvider: () => throw UnimplementedError(),
        ),
        storage: FakeDownloadStorage(),
      );

  final List<List<Track>> batches = [];
  final Set<String> downloadedKeys = {};
  final Map<String, DownloadTask> activeTasks = {};
  Completer<void>? batchGate;
  Completer<void>? batchResultGate;
  int? enqueuedOverride;

  @override
  DownloadedTrack? recordForTrack(Track track) {
    if (!downloadedKeys.contains(track.id.uri)) return null;
    return DownloadedTrack(
      originSourceKey: track.id.sourceKey,
      originSongId: track.id.id,
      title: track.title,
      filePath: '/downloads/${track.id.id}.mp3',
      sizeBytes: 1,
      downloadedAt: 1,
    );
  }

  @override
  DownloadTask? taskForTrack(Track track) => activeTasks[track.id.uri];

  @override
  Future<(int, int)> downloadBatch(
    Iterable<Track> tracks, {
    void Function(int enqueued)? onEnqueued,
  }) async {
    final list = tracks.toList();
    batches.add(list);
    final gate = batchGate;
    if (gate != null) await gate.future;
    final enqueued = enqueuedOverride ?? list.length;
    onEnqueued?.call(enqueued);
    final resultGate = batchResultGate;
    if (resultGate != null) await resultGate.future;
    return (enqueued, 0);
  }
}

/// 直接暴露内存任务列表的下载服务（任务区 UI 测试用）。
class _StaticTasksDownloadService extends DownloadService {
  _StaticTasksDownloadService(this.audioTasks)
    : super(
        catalog: CatalogService(registry: FakeSourceRegistry(const {})),
        repository: DownloadsRepository(
          databaseProvider: () => throw UnimplementedError(),
        ),
        storage: FakeDownloadStorage(),
      );

  final List<DownloadTask> audioTasks;
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  int cancelCalls = 0;

  @override
  bool get supported => true;

  @override
  Listenable get taskChanges => revision;

  @override
  List<DownloadTask> get tasks => audioTasks;

  @override
  DownloadTaskGroups get taskGroups => (
    running: [
      for (final task in audioTasks)
        if (task.status == DownloadTaskStatus.running) task,
    ],
    queued: [
      for (final task in audioTasks)
        if (task.status == DownloadTaskStatus.queued) task,
    ],
    failed: [
      for (final task in audioTasks)
        if (task.status == DownloadTaskStatus.failed) task,
    ],
  );

  @override
  void cancelTrack(Track track) => cancelCalls++;
}

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
    DownloadService? service,
    LibraryProvider? library,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DownloadSettings>.value(value: settings),
          ChangeNotifierProvider<DownloadService>.value(
            value: service ?? downloads,
          ),
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          if (saveAs != null) Provider<SaveAs>.value(value: saveAs),
          if (library != null)
            ChangeNotifierProvider<LibraryProvider>.value(value: library),
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

  /// 模拟设置页：页面在 MaterialApp 的内层 Navigator 里，弹层却挂 root。
  ///
  /// 这是「弹窗不关、页面被误退」bug 的复现条件；直接 home 挂载测不出来。
  Future<void> pumpNestedPage(
    WidgetTester tester,
    Widget page, {
    required DownloadService service,
    LibraryProvider? library,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DownloadSettings>.value(value: settings),
          ChangeNotifierProvider<DownloadService>.value(value: service),
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          if (library != null)
            ChangeNotifierProvider<LibraryProvider>.value(value: library),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Navigator(
            onGenerateRoute: (_) =>
                MaterialPageRoute<void>(builder: (_) => page),
          ),
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
    expect(find.text('任务'), findsOneWidget);
    expect(find.text('没有下载任务'), findsOneWidget);
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

  testWidgets('下载管理页：任务区显示进度 / 等待中 / 音质，等待超 20 首折叠', (tester) async {
    Track track(String id) => Track(
      id: TrackId('kw', id),
      title: '曲目 $id',
      origin: TrackOrigin.builtin,
      payload: {'songmid': id},
    );
    final running = DownloadTask(
      track: track('running'),
      kind: DownloadTaskKind.audio,
      quality: '320k',
    )..markRunning();
    final queued = [
      for (var i = 0; i < 21; i++)
        DownloadTask(
          track: track('$i'),
          kind: DownloadTaskKind.audio,
          quality: '128k',
        ),
    ];
    final service = _StaticTasksDownloadService([running, ...queued]);
    addTearDown(service.dispose);
    addTearDown(service.revision.dispose);

    await pumpPage(tester, const DownloadsManagePage(), service: service);

    expect(find.byKey(const Key('downloadsTask_kw:running')), findsOneWidget);
    expect(find.textContaining('下载中'), findsOneWidget);
    expect(find.textContaining('等待中'), findsWidgets);
    expect(find.textContaining('320K'), findsOneWidget);
    expect(find.text('还有 1 首等待中'), findsOneWidget);

    // 整行不承担取消；只有行尾按钮取消当前任务。
    await tester.tap(find.byKey(const Key('downloadsTask_kw:running')));
    await tester.pump();
    expect(service.cancelCalls, 0);
    await tester.tap(find.byKey(const Key('downloadsTaskCancel_kw:running')));
    await tester.pump();
    expect(service.cancelCalls, 1);

    // 顶部「取消全部」只撤等待任务（21 条），不包含运行中的那条。
    await tester.tap(find.byKey(const Key('downloadsCancelAllItem')));
    await tester.pump();
    expect(service.cancelCalls, 22);
  });

  Track makeQueueTrack(String id) => Track(
    id: TrackId('kw', id),
    title: '曲目 $id',
    origin: TrackOrigin.builtin,
    payload: {'songmid': id},
  );

  testWidgets('下载管理页：批量跳过已下载 / 进行中并按 key 去重', (tester) async {
    final downloaded = makeQueueTrack('1');
    final activeTrack = makeQueueTrack('2');
    final target = makeQueueTrack('3');
    final service = _RecordingDownloadService();
    await service.init();
    addTearDown(service.dispose);
    service.downloadedKeys.add(downloaded.id.uri);
    service.activeTasks[activeTrack.id.uri] = DownloadTask(
      track: activeTrack,
      kind: DownloadTaskKind.audio,
      quality: '320k',
    )..markRunning();
    backend.emit(
      BackendSnapshot(
        current: downloaded,
        queue: [downloaded, activeTrack, target, target],
        currentIndex: 0,
        duration: const Duration(seconds: 30),
      ),
    );

    await pumpPage(tester, const DownloadsManagePage(), service: service);
    await tester.tap(find.byKey(const Key('downloadsBatchQueueItem')));
    await tester.pumpAndSettle();

    expect(service.batches.single, hasLength(1));
    expect(service.batches.single.single.id, target.id);
  });

  testWidgets('下载管理页：批量提示在真正入队后显示并使用回调数量', (tester) async {
    final one = makeQueueTrack('1');
    final two = makeQueueTrack('2');
    final service = _RecordingDownloadService();
    await service.init();
    addTearDown(service.dispose);
    service.batchGate = Completer<void>();
    service.batchResultGate = Completer<void>();
    service.enqueuedOverride = 1;
    backend.emit(
      BackendSnapshot(
        current: one,
        queue: [one, two],
        currentIndex: 0,
        duration: const Duration(seconds: 30),
      ),
    );

    await pumpPage(tester, const DownloadsManagePage(), service: service);
    await tester.tap(find.byKey(const Key('downloadsBatchQueueItem')));
    await tester.pump();
    expect(service.batches.single, hasLength(2));
    expect(find.text('已加入下载队列（1 首）'), findsNothing, reason: '尚未入队');

    service.batchGate!.complete();
    await tester.pump();
    expect(find.text('已加入下载队列（1 首）'), findsOneWidget);

    service.batchResultGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('批量下载完成：成功 1，失败 0'), findsOneWidget);
  });

  testWidgets('下载管理页：没有可下载的歌曲时提示专用文案', (tester) async {
    final downloaded = makeQueueTrack('1');
    final activeTrack = makeQueueTrack('2');
    final service = _RecordingDownloadService();
    await service.init();
    addTearDown(service.dispose);
    service.downloadedKeys.add(downloaded.id.uri);
    service.activeTasks[activeTrack.id.uri] = DownloadTask(
      track: activeTrack,
      kind: DownloadTaskKind.audio,
      quality: '320k',
    )..markRunning();
    backend.emit(
      BackendSnapshot(
        current: downloaded,
        queue: [downloaded, activeTrack],
        currentIndex: 0,
        duration: const Duration(seconds: 30),
      ),
    );

    await pumpPage(tester, const DownloadsManagePage(), service: service);
    await tester.tap(find.byKey(const Key('downloadsBatchQueueItem')));
    await tester.pumpAndSettle();

    expect(service.batches, isEmpty);
    expect(find.text('没有可下载的歌曲（已下载或正在下载）'), findsOneWidget);
  });

  testWidgets('下载管理页（嵌套 Navigator）：选歌单弹层关闭，页面保留并启动批量', (tester) async {
    final repository = FakeLibraryRepository();
    addTearDown(repository.dispose);
    final playlistId = await repository.createPlaylist('测试歌单');
    await repository.addTrackToPlaylist(
      playlistId,
      PlaylistTrack(
        playlistId: playlistId,
        sourceKey: 'kw',
        songId: '1',
        title: '测试歌曲',
        addedAt: 1,
        raw: const {'songmid': '1'},
      ),
    );
    final library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    await library.refreshPlaylists();
    addTearDown(library.dispose);
    final service = _RecordingDownloadService();
    await service.init();
    addTearDown(service.dispose);

    await pumpNestedPage(
      tester,
      const DownloadsManagePage(),
      service: service,
      library: library,
    );

    await tester.tap(find.byKey(const Key('downloadsBatchPlaylistItem')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('downloadsPlaylist_$playlistId')), findsOneWidget);

    await tester.tap(find.byKey(Key('downloadsPlaylist_$playlistId')));
    await tester.pumpAndSettle();

    // 弹层关闭、页面仍在，歌单已交给批量流程。
    expect(find.byType(DownloadsManagePage), findsOneWidget);
    expect(find.byKey(Key('downloadsPlaylist_$playlistId')), findsNothing);
    expect(service.batches.single.single.id, const TrackId('kw', '1'));
  });

  testWidgets('下载管理页（嵌套 Navigator）：残留清理展示数量 / 文件名，取消与删除都正确', (tester) async {
    final storage = FakeDownloadStorage();
    storage.files['/downloads/orphan.mp3'] = [1];
    storage.files['/downloads/orphan.lrc'] = [2];
    storage.files['/downloads/cover.png'] = [3];
    storage.files['/downloads/notes.txt'] = [4];
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

    await pumpNestedPage(tester, const DownloadsManagePage(), service: service);

    await tester.tap(find.byKey(const Key('downloadsCleanupOrphansItem')));
    await tester.pumpAndSettle();
    // 只列应用可识别的残留：音频 / 歌词 / 封面，notes.txt 不参与。
    expect(find.textContaining('3 个可清理的残留文件'), findsOneWidget);
    expect(find.textContaining('orphan.mp3'), findsOneWidget);
    expect(find.textContaining('notes.txt'), findsNothing);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadsManagePage), findsOneWidget);
    expect(storage.files.containsKey('/downloads/orphan.mp3'), isTrue);
    expect(storage.files.containsKey('/downloads/notes.txt'), isTrue);

    await tester.tap(find.byKey(const Key('downloadsCleanupOrphansItem')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadsManagePage), findsOneWidget);
    expect(storage.files.containsKey('/downloads/orphan.mp3'), isFalse);
    expect(storage.files.containsKey('/downloads/orphan.lrc'), isFalse);
    expect(storage.files.containsKey('/downloads/cover.png'), isFalse);
    expect(storage.files.containsKey('/downloads/notes.txt'), isTrue);
    expect(find.text('已清理 3 个残留文件'), findsOneWidget);
  });
}
