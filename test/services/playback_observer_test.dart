import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/playback/default_playback_facade.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/managers/image_preload_manager.dart';
import 'package:molia/services/app_presence.dart';
import 'package:molia/services/covers/cover_resolution.dart';
import 'package:molia/services/data_saver_service.dart';
import 'package:molia/services/playback_observer.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_library_repository.dart';
import '../support/fake_cover_index.dart';
import '../support/fakes.dart';

/// 播放观察者：快照副作用扇出（最后播放 / 小组件 / 历史 /
/// 预取 / 补封面 / 通知权限）。
///
/// 假 facade（真实 facade + 假后端）+ 假副作用入口；断言只经观察者接口与
/// 注入的假入口，不读私有字段。会话落盘不在本文件的职责面内（单写者见
/// `test/playback_session_coordinator_test.dart`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Track track(String id, {String? artwork}) => Track(
        id: TrackId('fake', id),
        title: 'Title $id',
        artists: [Artist(name: 'Artist $id')],
        album: 'Album $id',
        duration: const Duration(seconds: 30),
        artwork: artwork == null ? null : Artwork(uri: Uri.parse(artwork)),
        origin: TrackOrigin.lx,
        payload: {'songmid': id},
      );

  BackendSnapshot snapshot(
    Track? current, {
    List<Track>? queue,
    bool playing = true,
    Duration position = Duration.zero,
    PlaybackContext? context,
  }) {
    // 与真实后端一致：next / previous / upNext 由队列与下标派生。
    final tracks = queue ?? [if (current != null) current];
    final index = current == null
        ? -1
        : tracks.indexWhere((item) => item.id.uri == current.id.uri);
    return BackendSnapshot(
      current: current,
      queue: tracks,
      currentIndex: index,
      next: index >= 0 && index + 1 < tracks.length ? tracks[index + 1] : null,
      previous: index > 0 ? tracks[index - 1] : null,
      upNext: index >= 0 ? tracks.sublist(index + 1) : const [],
      isPlaying: playing,
      position: position,
      duration: current?.duration ?? Duration.zero,
      context: context,
    );
  }

  /// 各副作用入口的调用台账（同步发起的按调用顺序记录）。
  late List<String> log;
  late _RecordingLibraryStore libraryStore;
  late _RecordingPreloader preloader;
  late List<Map<String, Object?>> widgetPayloads;
  late int notificationRequests;
  late FakePlaybackBackend backend;
  late DefaultPlaybackFacade facade;

  PlaybackObserver buildObserver({
    Future<String?> Function(Track track)? artworkResolver,
    CoverResolver? coverResolver,
    DataSaverService? dataSaver,
    GlobalKey<NavigatorState>? navigatorKey,
    AppPresence? presence,
  }) {
    log = [];
    widgetPayloads = [];
    notificationRequests = 0;
    libraryStore = _RecordingLibraryStore(log);
    preloader = _RecordingPreloader(log);
    return PlaybackObserver(
      facade: facade,
      dataSaver: dataSaver,
      libraryRepository: libraryStore,
      widgetUpdater: (payload) async {
        log.add('widget');
        widgetPayloads.add(payload);
      },
      albumArtPreloader: preloader,
      artworkResolver: artworkResolver,
      coverResolver: coverResolver,
      navigatorKey: navigatorKey,
      requestNotificationPermission: () async {
        log.add('notify');
        notificationRequests++;
      },
      presence: presence,
    )..attach();
  }

  setUp(() {
    backend = FakePlaybackBackend();
    facade = DefaultPlaybackFacade(backend: backend);
  });

  testWidgets('切歌：各副作用发生且同步发起的顺序固定', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final observer = buildObserver(navigatorKey: navigatorKey);
    addTearDown(observer.dispose);
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigatorKey, home: const SizedBox.shrink()),
    );

    final item = track('a', artwork: 'https://img.example/a.jpg');
    final next = track('b', artwork: 'https://img.example/b.jpg');
    backend.emit(
      snapshot(
        item,
        queue: [item, next],
        context: const PlaybackContext(name: '收藏', type: 'lx', uri: 'lx:收藏'),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 各副作用均已发生。
    expect(widgetPayloads, hasLength(1));
    expect(widgetPayloads.single['songName'], 'Title a');
    expect(widgetPayloads.single['artistName'], 'Artist a');
    expect(widgetPayloads.single['albumArtUrl'], 'https://img.example/a.jpg');
    expect(widgetPayloads.single['isPlaying'], isTrue);
    expect(libraryStore.history, hasLength(1));
    expect(libraryStore.history.single.songId, 'a');
    expect(libraryStore.history.single.raw['songmid'], 'a');
    expect(notificationRequests, 1);
    expect(preloader.preloaded, hasLength(1));
    expect(preloader.preloaded.single.current?.id.uri, 'fake:a');
    expect(preloader.preloaded.single.next?.id.uri, 'fake:b');

    // 最后播放信息落盘并对外可读。
    await observer.ready;
    expect(observer.lastPlayedTrackName, 'Title a');
    expect(observer.lastPlayedArtists, 'Artist a');
    expect(observer.lastPlayedImageUrl, 'https://img.example/a.jpg');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('last_played_track_name'), 'Title a');

    // 顺序：widget → history 同步发起；通知权限在播放态判定后发起；
    // 预取在微任务中执行（跨 async gap 不用 context），落在最后。
    expect(log, ['widget', 'history', 'notify', 'preload']);
  });

  test('省流：本地封面照常传小组件，远程封面置空', () async {
    final dataSaver = DataSaverService(
      prefs: await SharedPreferences.getInstance(),
      cellularProbe: () async => true,
    );
    await dataSaver.init(monitor: false);
    await dataSaver.setEnabled(true);
    addTearDown(dataSaver.dispose);
    expect(dataSaver.blockNetworkArtwork, isTrue);

    var displayUrl = 'file:///data/user/0/molia/custom_covers/track_a.jpg';
    final coverIndex = FakeCoverIndex(customUrls: {'fake:a': displayUrl});
    final observer = buildObserver(
      dataSaver: dataSaver,
      coverResolver: CoverResolver(coverIndex),
    );
    addTearDown(observer.dispose);

    final local = track('a', artwork: 'https://img.example/a.jpg');
    backend.emit(snapshot(local));
    expect(
      widgetPayloads.single['albumArtUrl'],
      displayUrl,
      reason: '本地自定义 / 默认封面不需要网络，省流时照常展示',
    );

    displayUrl = 'https://img.example/b.jpg';
    final remote = track('b', artwork: displayUrl);
    backend.emit(snapshot(remote));
    expect(widgetPayloads.last['albumArtUrl'], '', reason: '远程封面在省流时仍置空');
  });

  test('切歌：无封面时补取并回写队列（widget 再次刷新封面）', () async {
    final observer = buildObserver(
      artworkResolver: (t) async => 'https://img.example/${t.id.id}.jpg',
    );
    addTearDown(observer.dispose);

    final item = track('a');
    backend.emit(snapshot(item));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(backend.lastArtworkTrackUri, 'fake:a');
    expect(backend.lastArtworkUri, 'https://img.example/a.jpg');
    // 补图成功后再次刷新小组件（payload 以 facade 当前快照为准）。
    expect(widgetPayloads, hasLength(2));
  });

  test('同曲目快照变化不重复扇出；首次出声只请求一次通知权限', () async {
    final observer = buildObserver();
    addTearDown(observer.dispose);

    final item = track('a');
    backend.emit(snapshot(item));
    backend.emit(snapshot(item, position: const Duration(seconds: 2)));
    backend.emit(
      snapshot(item, playing: false, position: const Duration(seconds: 4)),
    );

    // 同曲目：历史 / 小组件不重复；通知权限只请求一次。
    expect(libraryStore.history, hasLength(1));
    expect(widgetPayloads, hasLength(1));
    expect(notificationRequests, 1);
  });

  test('停止后重播同一首：去重重置，副作用再次发生', () async {
    final observer = buildObserver();
    addTearDown(observer.dispose);

    final item = track('a');
    backend.emit(snapshot(item));
    // 停止播放（曲目清空）：去重键重置。
    backend.emit(snapshot(null));
    backend.emit(snapshot(item));

    expect(libraryStore.history, hasLength(2));
    expect(widgetPayloads, hasLength(2));
  });

  testWidgets('后台期不预取封面；恢复后补一次', (tester) async {
    final presence = AppPresence();
    final navigatorKey = GlobalKey<NavigatorState>();
    final observer = buildObserver(
      navigatorKey: navigatorKey,
      presence: presence,
    );
    addTearDown(observer.dispose);
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigatorKey, home: const SizedBox.shrink()),
    );
    await tester.pump();

    // 托盘隐藏期间切歌：历史 / 小组件照常，封面预取被门控拦下。
    presence.markTrayHidden();
    final item = track('a', artwork: 'https://img.example/a.jpg');
    backend.emit(snapshot(item));
    await tester.pump();
    await tester.pump();
    expect(notificationRequests, 1);
    expect(preloader.preloaded, isEmpty);

    // 恢复：等休眠后的重建帧落定，补一次预取。
    presence.markVisible();
    await tester.pump();
    await tester.pump();
    expect(preloader.preloaded, hasLength(1));
    expect(preloader.preloaded.single.current?.id.uri, 'fake:a');
  });
}

/// 记录历史写入的假 store（复用内存资料库的公开接口）。
class _RecordingLibraryStore extends FakeLibraryRepository {
  _RecordingLibraryStore(this._log);

  final List<String> _log;

  /// 已写入的历史条目。
  final List<PlayHistoryEntry> history = [];

  @override
  Future<void> addHistoryEntry(PlayHistoryEntry entry) async {
    _log.add('history');
    history.add(entry);
  }
}

/// 记录预取请求的假策略（覆写公开接口）。
class _RecordingPreloader extends AlbumArtPreloadStrategy {
  _RecordingPreloader(this._log);

  final List<String> _log;

  /// 预取请求（当前 / 下一首）。
  final List<({Track? current, Track? next})> preloaded = [];

  @override
  Future<void> preloadForPlayback({
    required BuildContext context,
    Track? currentTrack,
    Track? nextTrack,
    List<Track>? upcomingTracks,
  }) async {
    _log.add('preload');
    preloaded.add((current: currentTrack, next: nextTrack));
  }
}
