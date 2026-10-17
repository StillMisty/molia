import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/playback/default_playback_facade.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/managers/image_preload_manager.dart';
import 'package:molia/services/playback_observer.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

/// 播放观察者：快照副作用扇出（最后播放 / 播放上下文 / 小组件 / 历史 /
/// 会话落盘 / 预取 / 补封面 / 通知权限）。
///
/// 假 facade（真实 facade + 假后端）+ 假 store；断言只经观察者接口与注入的
/// 假入口，不读私有字段。时钟注入让「1s 节流」边界可精确验证。
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
    // 与真实后端一致：next/upcoming/upNext/history 由队列与下标派生。
    final tracks = queue ?? [if (current != null) current];
    final index = current == null
        ? -1
        : tracks.indexWhere((item) => item.id.uri == current.id.uri);
    return BackendSnapshot(
      current: current,
      queue: tracks,
      currentIndex: index,
      next: index >= 0 && index + 1 < tracks.length ? tracks[index + 1] : null,
      upcoming: index >= 0 ? tracks.sublist(index + 1) : const [],
      upNext: index >= 0 ? tracks.sublist(index + 1) : const [],
      history: index > 0 ? tracks.sublist(0, index) : const [],
      isPlaying: playing,
      position: position,
      duration: current?.duration ?? Duration.zero,
      context: context,
    );
  }

  /// 各副作用入口的调用台账（同步发起的按调用顺序记录）。
  late List<String> log;
  late _RecordingSessionStore sessionStore;
  late _RecordingLibraryStore libraryStore;
  late _RecordingPreloader preloader;
  late List<Map<String, Object?>> widgetPayloads;
  late List<({String contextUri, String? imageUrl})> playContexts;
  late int notificationRequests;
  late DateTime now;
  late FakePlaybackBackend backend;
  late DefaultPlaybackFacade facade;

  PlaybackObserver buildObserver({
    Future<String?> Function(Track track)? artworkResolver,
    GlobalKey<NavigatorState>? navigatorKey,
  }) {
    log = [];
    widgetPayloads = [];
    playContexts = [];
    notificationRequests = 0;
    now = DateTime(2026, 1, 1, 12);
    sessionStore = _RecordingSessionStore(log);
    libraryStore = _RecordingLibraryStore(log);
    preloader = _RecordingPreloader(log);
    return PlaybackObserver(
      facade: facade,
      sessionStore: sessionStore,
      libraryRepository: libraryStore,
      playContextWriter: ({
        required contextUri,
        required contextType,
        required contextName,
        required imageUrl,
        required lastPlayedAt,
      }) async {
        log.add('context');
        playContexts.add((contextUri: contextUri, imageUrl: imageUrl));
      },
      widgetUpdater: (payload) async {
        log.add('widget');
        widgetPayloads.add(payload);
      },
      albumArtPreloader: preloader,
      artworkResolver: artworkResolver,
      navigatorKey: navigatorKey,
      requestNotificationPermission: () async {
        log.add('notify');
        notificationRequests++;
      },
      clock: () => now,
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
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      home: const SizedBox.shrink(),
    ));

    final item = track('a', artwork: 'https://img.example/a.jpg');
    final next = track('b', artwork: 'https://img.example/b.jpg');
    backend.emit(snapshot(
      item,
      queue: [item, next],
      context: const PlaybackContext(name: '收藏', type: 'lx', uri: 'lx:收藏'),
    ));
    await tester.pump();
    await tester.pump();

    // 各副作用均已发生。
    expect(playContexts.single.contextUri, 'lx:收藏');
    expect(playContexts.single.imageUrl, 'https://img.example/a.jpg');
    expect(widgetPayloads, hasLength(1));
    expect(widgetPayloads.single['songName'], 'Title a');
    expect(widgetPayloads.single['artistName'], 'Artist a');
    expect(widgetPayloads.single['albumArtUrl'], 'https://img.example/a.jpg');
    expect(widgetPayloads.single['isPlaying'], isTrue);
    expect(libraryStore.history, hasLength(1));
    expect(libraryStore.history.single.songId, 'a');
    expect(libraryStore.history.single.raw['songmid'], 'a');
    expect(sessionStore.saves, hasLength(1));
    expect(sessionStore.saves.single.index, 0);
    expect(sessionStore.saves.single.tracks.first.id.uri, 'fake:a');
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

    // 顺序：context → widget → history → session 同步发起；
    // 通知权限在播放态判定后发起；预取在微任务中执行（跨 async gap 不用
    // context），落在最后。
    expect(
      log,
      ['context', 'widget', 'history', 'session', 'notify', 'preload'],
    );
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

  test('暂停：强制落盘最新进度（不等节流窗口）', () async {
    final observer = buildObserver();
    addTearDown(observer.dispose);

    final item = track('a');
    backend.emit(snapshot(item, position: const Duration(seconds: 3)));
    expect(sessionStore.saves, hasLength(1));

    // 暂停：即使仍在节流窗口内也强制保存（进度以最新值为准）。
    now = now.add(const Duration(milliseconds: 100));
    backend.emit(
        snapshot(item, playing: false, position: const Duration(seconds: 5)));

    expect(sessionStore.saves, hasLength(2));
    expect(sessionStore.saves.last.position, const Duration(seconds: 5));
  });

  test('进度 tick：只写轻量进度键（1s 节流），不整份重写会话', () async {
    final observer = buildObserver();
    addTearDown(observer.dispose);

    final item = track('a');
    backend.emit(snapshot(item));
    expect(sessionStore.saves, hasLength(1));
    expect(sessionStore.positions, isEmpty);

    // 节流窗口内：进度 tick 不落盘。
    now = now.add(const Duration(milliseconds: 300));
    backend.emit(snapshot(item, position: const Duration(seconds: 1)));
    now = now.add(const Duration(milliseconds: 500));
    backend.emit(snapshot(item, position: const Duration(seconds: 2)));
    expect(sessionStore.positions, isEmpty);

    // 跨过 1s 窗口：只写轻量进度键（会话 JSON 不重写）。
    now = now.add(const Duration(milliseconds: 400));
    backend.emit(snapshot(item, position: const Duration(seconds: 3)));
    expect(sessionStore.positions, [3000]);
    expect(sessionStore.saves, hasLength(1));

    // 距上次整份落盘满 1 分钟：整份刷新一次（savedAt 抢占语义）。
    now = now.add(const Duration(minutes: 1));
    backend.emit(snapshot(item, position: const Duration(seconds: 4)));
    expect(sessionStore.saves, hasLength(2));
    expect(sessionStore.saves.last.position, const Duration(seconds: 4));
  });

  test('同曲目快照变化不重复扇出；首次出声只请求一次通知权限', () async {
    final observer = buildObserver();
    addTearDown(observer.dispose);

    final item = track('a');
    backend.emit(snapshot(item));
    now = now.add(const Duration(seconds: 2));
    backend.emit(snapshot(item, position: const Duration(seconds: 2)));
    now = now.add(const Duration(seconds: 2));
    backend.emit(
        snapshot(item, playing: false, position: const Duration(seconds: 4)));

    // 同曲目：历史 / 小组件不重复；通知权限只请求一次。
    expect(libraryStore.history, hasLength(1));
    expect(widgetPayloads, hasLength(1));
    // 无播放上下文（context 为空）时不写「最近播放」。
    expect(playContexts, isEmpty);
    expect(notificationRequests, 1);
    // 暂停仍触发一次强制落盘（进度以最新值为准）。
    expect(sessionStore.saves.last.position, const Duration(seconds: 4));
  });

  test('停止后重播同一首：去重重置，副作用再次发生', () async {
    final observer = buildObserver();
    addTearDown(observer.dispose);

    final item = track('a');
    backend.emit(snapshot(item));
    // 停止播放（曲目清空）：去重键重置。
    backend.emit(snapshot(null));
    now = now.add(const Duration(seconds: 2));
    backend.emit(snapshot(item));

    expect(libraryStore.history, hasLength(2));
    expect(widgetPayloads, hasLength(2));
  });
}

/// 记录会话落盘的假 store（覆写公开接口，不读私有字段）。
class _RecordingSessionStore extends PlaybackSessionStore {
  _RecordingSessionStore(this._log);

  final List<String> _log;

  /// 整份落盘的会话（调用顺序即保存顺序）。
  final List<PlaybackSession> saves = [];

  /// 轻量进度落盘（毫秒）。
  final List<int> positions = [];

  @override
  Future<void> save(PlaybackSession session) async {
    _log.add('session');
    saves.add(session);
  }

  @override
  Future<void> savePosition(int positionMs) async {
    positions.add(positionMs);
  }
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
