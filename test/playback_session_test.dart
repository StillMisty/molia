import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// 上次播放会话：持久化往返 + 冷启动恢复（封面/进度/继续播放）。
Track _track(String id, {String? artwork}) => Track(
      id: TrackId('fake', id),
      title: 'Title $id',
      artists: [Artist(name: 'Artist $id')],
      album: 'Album $id',
      duration: const Duration(seconds: 30),
      artwork: artwork == null ? null : Artwork(uri: Uri.parse(artwork)),
      origin: TrackOrigin.lx,
      payload: {'id': id, 'songmid': 'mid_$id'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('PlaybackSessionStore 往返：队列/下标/进度/模式/上下文/raw 原样', () async {
    final store = PlaybackSessionStore();
    final session = PlaybackSession(
      tracks: [
        _track('a', artwork: 'https://img.example/a.jpg'),
        _track('b'),
      ],
      index: 1,
      position: const Duration(seconds: 42),
      mode: PlayMode.shuffle,
      context: const PlaybackContext(
        name: '收藏',
        type: 'lx',
        uri: 'lx:收藏',
      ),
    );

    await store.save(session);
    final loaded = await store.load();

    expect(loaded, isNotNull);
    expect(loaded!.tracks, hasLength(2));
    expect(loaded.index, 1);
    expect(loaded.position, const Duration(seconds: 42));
    expect(loaded.mode, PlayMode.shuffle);
    expect(loaded.context?.name, '收藏');
    expect(loaded.tracks[0].artwork?.uri.toString(),
        'https://img.example/a.jpg');
    // raw（payload）必须原样保留：恢复播放依赖它重新取链。
    expect(loaded.tracks[0].payload['songmid'], 'mid_a');
  });

  test('冷启动恢复：展示上次曲目/封面/进度，可继续播放并 seek 回进度', () async {
    final store = PlaybackSessionStore();
    await store.save(PlaybackSession(
      tracks: [
        _track('a'),
        _track('b', artwork: 'https://img.example/b.jpg'),
      ],
      index: 1,
      position: const Duration(seconds: 20),
      mode: PlayMode.sequential,
      context: const PlaybackContext(name: '队列', type: 'lx', uri: 'lx:队列'),
    ));

    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    // 恢复态：UI 能拿到曲目/封面/进度/队列。
    expect(provider.hasRestoredSession, isTrue);
    expect(provider.hasTrack, isTrue);
    expect(provider.snapshot.current?.title, 'Title b');
    expect(provider.snapshot.current?.artwork?.uri.toString(),
        'https://img.example/b.jpg');
    expect(provider.currentTrackId, const TrackId('fake', 'b'));
    // 恢复会话保留队列里 index-1：左侧「上一首」封面不因重启丢失。
    expect(provider.snapshot.history.last.title, 'Title a');
    expect(provider.position.value, const Duration(seconds: 20));
    expect(provider.snapshot.next, isNull);
    expect(provider.snapshot.upcoming, isEmpty);

    // 恢复态 seek：只更新保存的进度，不碰真实播放。
    await provider.seekToPosition(25000);
    expect(provider.position.value, const Duration(seconds: 25));
    expect(backend.calls.where((call) => call == 'seek'), isEmpty);

    // 点播放 = 重新取链 + 跳回进度。
    await provider.togglePlayPause();
    expect(backend.calls, contains('load'));
    expect(backend.calls, contains('seek'));
    expect(provider.hasRestoredSession, isFalse);
    // 恢复播放后进度通道交还底层：落在保存的进度上。
    expect(provider.position.value, const Duration(seconds: 25));
  });

  test('真实播放后保存会话：新实例可恢复（含 raw）', () async {
    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    backend.emit(BackendSnapshot(
      current: _track('a', artwork: 'https://img.example/a.jpg'),
      queue: [_track('a'), _track('b')],
      currentIndex: 0,
      upcoming: [_track('b')],
      isPlaying: true,
      position: const Duration(seconds: 7),
      duration: const Duration(seconds: 30),
    ));
    // 保存是异步的：让微任务/SharedPreferences 写入完成。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final session = await PlaybackSessionStore().load();
    expect(session, isNotNull);
    expect(session!.tracks, hasLength(2));
    expect(session.index, 0);
    expect(session.tracks[0].payload['songmid'], 'mid_a');
  });
}
