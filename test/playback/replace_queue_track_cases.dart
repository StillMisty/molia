import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

/// 记录协调者的提交次数（断言每个换源命令只写一次会话）。
class _CountingSessionStore extends PlaybackSessionStore {
  final List<PlaybackSession> saves = [];

  @override
  Future<void> save(PlaybackSession session) {
    saves.add(session);
    return super.save(session);
  }
}

/// 换源：`PlaybackProvider.replaceQueueTrack`（真实队列 / 冷启动恢复态）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Track track(String id, {String sourceKey = 'fake', String title = 'Title'}) =>
      Track(
        id: TrackId(sourceKey, id),
        title: title,
        artists: [Artist(name: 'Artist')],
        origin: TrackOrigin.builtin,
        payload: {'songmid': id},
      );

  test('真实队列命中：facade 替换全部同 id 曲目并更新快照', () async {
    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);

    final old = track('a');
    final other = track('b');
    backend.emit(BackendSnapshot(
      current: old,
      queue: [other, old],
      currentIndex: 1,
      isPlaying: true,
    ));

    final replacement = track('a', sourceKey: 'kg', title: '新版本');
    final hit = await provider.replaceQueueTrack(old, replacement);

    expect(hit, isTrue);
    expect(backend.lastReplacedTrackUri, 'fake:a');
    expect(backend.lastReplacedTrack, same(replacement));
    expect(provider.snapshot.queue.map((t) => t.id.uri), ['fake:b', 'kg:a']);
    expect(provider.snapshot.current?.title, '新版本');
  });

  test('未命中：返回 false 且不调用 facade', () async {
    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);

    backend.emit(BackendSnapshot(
      current: track('b'),
      queue: [track('b')],
      currentIndex: 0,
      isPlaying: true,
    ));

    final hit = await provider.replaceQueueTrack(
      track('a'),
      track('a', sourceKey: 'kg'),
    );

    expect(hit, isFalse);
    expect(
      backend.calls.where((call) => call.startsWith('replaceQueueTrack')),
      isEmpty,
    );
  });

  test('恢复态会话命中：替换会话队列、更新恢复快照并落盘', () async {
    final old = track('a');
    final other = track('b');
    await PlaybackSessionStore().save(PlaybackSession(
      tracks: [old, other],
      index: 0,
      position: const Duration(seconds: 42),
      context: const PlaybackContext(name: 'ctx', type: 'lx', uri: 'lx:ctx'),
    ));

    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;
    expect(provider.hasRestoredSession, isTrue);

    final replacement = track('a', sourceKey: 'kg');
    final hit = await provider.replaceQueueTrack(old, replacement);

    expect(hit, isTrue);
    expect(backend.calls, isEmpty, reason: '恢复态不触碰真实后端');
    expect(provider.snapshot.current?.id, const TrackId('kg', 'a'));
    expect(provider.snapshot.current?.title, 'Title');
    expect(provider.snapshot.queue.map((t) => t.id.uri), ['kg:a', 'fake:b']);

    // 会话已落盘：冷启动恢复读的是换源后的队列。
    final saved = await PlaybackSessionStore().load();
    expect(saved!.tracks.first.id.sourceKey, 'kg');
    expect(saved.position, const Duration(seconds: 42));
  });

  test('交接窗口同时命中：live 与恢复态都更新，命令只提交一次', () async {
    final old = track('a');
    final other = track('b');
    await PlaybackSessionStore().save(PlaybackSession(
      tracks: [old, other],
      index: 0,
      position: const Duration(seconds: 12),
    ));

    final store = _CountingSessionStore();
    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(
      backend: backend,
      sessionStore: store,
    );
    addTearDown(provider.dispose);
    await provider.preferencesReady;
    expect(provider.hasRestoredSession, isTrue);

    // 交接窗口：facade 已有队列但还没有当前曲目，恢复态仍然保留。
    backend.emit(BackendSnapshot(queue: [old, other], currentIndex: -1));

    final replacement = track('a', sourceKey: 'kg');
    final hit = await provider.replaceQueueTrack(old, replacement);

    expect(hit, isTrue);
    expect(backend.lastReplacedTrackUri, 'fake:a');
    expect(provider.snapshot.queue.map((t) => t.id.uri), ['kg:a', 'fake:b']);
    expect(store.saves, hasLength(1), reason: '一个换源命令只提交一次');
    expect(store.saves.single.tracks.map((t) => t.id.uri), ['kg:a', 'fake:b']);

    // 返回即已落盘：冷启动恢复读的是换源后的队列。
    final saved = await PlaybackSessionStore().load();
    expect(saved!.tracks.map((t) => t.id.uri), ['kg:a', 'fake:b']);
  });
}
