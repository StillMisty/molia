import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/downloads_manage_page.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/download/download_manager.dart';
import 'package:molia/services/download/download_queue.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

Track _track(int index) => Track(
  id: TrackId('wy', '$index'),
  title: 'Song $index',
  artists: const [Artist(name: 'Artist')],
  duration: const Duration(seconds: 100),
  origin: TrackOrigin.builtin,
);

DownloadTask _queuedTask(int index) => DownloadTask(
  track: _track(index),
  kind: DownloadTaskKind.audio,
  quality: '320k',
);

/// 只实现管理页需要的命令面：任务分组 + 取消；其它命令不应被页面触发。
class _FakeDownloads extends DownloadManager {
  _FakeDownloads(this.queued);

  final List<DownloadTask> queued;
  final List<Track> cancelled = [];
  final ChangeNotifier _changes = ChangeNotifier();

  @override
  bool get supported => true;

  @override
  bool get publisherSupported => false;

  @override
  bool get notificationsSupported => false;

  @override
  bool get initialized => true;

  @override
  Future<void> get ready async {}

  @override
  Future<void> init() async {}

  @override
  Listenable get taskChanges => _changes;

  @override
  DownloadTaskGroups get taskGroups =>
      (running: const [], queued: List.unmodifiable(queued), failed: const []);

  @override
  DownloadTask? taskForTrack(Track track) => null;

  @override
  Future<void> retryTask(DownloadTask task) async {}

  @override
  void dismissTask(DownloadTask task) {}

  @override
  void cancelTrack(Track track) {
    cancelled.add(track);
    queued.removeWhere((task) => task.track.id == track.id);
    _changes.notifyListeners();
  }

  @override
  Future<void> download(
    Track track, {
    String? quality,
    bool includeLyrics = true,
    bool includeCover = true,
  }) async {}

  @override
  Future<DownloadTask> enqueueDownload(
    Track track, {
    String? quality,
    bool includeLyrics = true,
    bool includeCover = true,
  }) async => _queuedTask(0);

  @override
  Future<void> downloadLyrics(Track track) async {}

  @override
  Future<void> downloadCover(Track track) async {}

  @override
  List<({int index, Track track})> batchCandidates(Iterable<Track> tracks) =>
      const [];

  @override
  Future<(int, int)> downloadBatch(
    Iterable<Track> tracks, {
    void Function(int enqueued)? onEnqueued,
  }) async => (0, 0);

  @override
  Future<void> delete(DownloadedTrack record) async {}

  @override
  Future<(int, int)> importLocalFiles(Iterable<String> paths) async => (0, 0);

  @override
  Future<LocalRelocateResult> relocate(
    DownloadedTrack record,
    String newPath,
  ) async => LocalRelocateResult.fileMissing;

  @override
  Future<DownloadedTrack?> refreshLocalMetadata(DownloadedTrack record) async =>
      null;

  @override
  String defaultQualityFor(Track track) => '320k';

  @override
  Future<Uri?> localUriFor(Track track, {String? quality}) async => null;
}

Future<void> _pumpPage(WidgetTester tester, DownloadManager downloads) async {
  final playback = buildTestPlaybackProvider(facade: FakePlaybackFacade());
  addTearDown(playback.dispose);
  await playback.preferencesReady;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<DownloadManager>.value(value: downloads),
        ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
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
        home: const DownloadsManagePage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('等待中的任务可以行内取消，点击后从队列移除', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final downloads = _FakeDownloads([_queuedTask(1)]);
    addTearDown(downloads.dispose);
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpPage(tester, downloads);

    final cancel = find.byKey(const Key('downloadsTaskCancel_wy:1'));
    expect(cancel, findsOneWidget);
    expect(
      tester.widget<M3EIconButton>(cancel).onPressed,
      isNotNull,
      reason: 'queued 任务也必须能取消',
    );

    await tester.tap(cancel);
    await tester.pumpAndSettle();

    expect(downloads.cancelled.map((track) => track.id.uri), ['wy:1']);
    expect(find.byKey(const Key('downloadsTask_wy:1')), findsNothing);
  });

  testWidgets('取消全部等待先确认；超过首屏行数可展开', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final downloads = _FakeDownloads([
      for (var i = 0; i < 21; i++) _queuedTask(i),
    ]);
    addTearDown(downloads.dispose);
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpPage(tester, downloads);

    // 首屏只渲染 20 条，第 21 条收在可展开入口后面。
    expect(find.byKey(const Key('downloadsTask_wy:20')), findsNothing);
    expect(find.text('还有 1 首等待中'), findsOneWidget);

    await tester.tap(find.byKey(const Key('downloadsWaitingToggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('downloadsTask_wy:20')), findsOneWidget);
    // 展开后标题不再说「还有」，改为总数 + 收起动作。
    expect(find.text('等待中 21 首'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);

    // 取消全部：弹确认，取消不执行。
    await tester.tap(find.byKey(const Key('downloadsOverflowButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消全部'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('downloadsCancelAllConfirm')), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(downloads.cancelled, isEmpty);
    expect(downloads.queued, hasLength(21));

    // 确认后一次清空等待队列。
    await tester.tap(find.byKey(const Key('downloadsOverflowButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消全部'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('downloadsCancelAllConfirm')));
    await tester.pumpAndSettle();

    expect(downloads.cancelled, hasLength(21));
    expect(downloads.queued, isEmpty);
  });
}
