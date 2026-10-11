import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/playback/default_playback_facade.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

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
    final facade = DefaultPlaybackFacade(backend: backend);
    final provider =
        PlaybackProvider(facade: facade, messenger: FakeMessenger());
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
    expect(provider.snapshot.queue.map((t) => t.id.uri),
        ['fake:b', 'kg:a']);
    expect(provider.snapshot.current?.title, '新版本');
  });

  test('未命中：返回 false 且不调用 facade', () async {
    final backend = FakePlaybackBackend();
    final facade = DefaultPlaybackFacade(backend: backend);
    final provider =
        PlaybackProvider(facade: facade, messenger: FakeMessenger());
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
    SharedPreferences.setMockInitialValues({
      'playback_session_v1': jsonEncode(
        PlaybackSession(
          tracks: [old, other],
          index: 0,
          position: const Duration(seconds: 42),
          context: const PlaybackContext(name: 'ctx', type: 'lx', uri: 'lx:ctx'),
        ).toJson(),
      ),
    });

    final backend = FakePlaybackBackend();
    final facade = DefaultPlaybackFacade(backend: backend);
    final provider =
        PlaybackProvider(facade: facade, messenger: FakeMessenger());
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
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('playback_session_v1')!)
        as Map<String, dynamic>;
    final savedTracks = saved['tracks'] as List;
    expect((savedTracks.first as Map)['sourceKey'], 'kg');
    expect(saved['positionMs'], 42000);
  });
}
