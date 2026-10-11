import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/playback/default_playback_facade.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

/// 封面补取：曲目起播无封面时经注入 resolver 取图并回写队列。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Track track(String id, {Artwork? artwork}) => Track(
        id: TrackId('fake', id),
        title: 'Title $id',
        artists: [Artist(name: 'Artist $id')],
        artwork: artwork,
        origin: TrackOrigin.builtin,
        payload: {'songmid': id},
      );

  test('无封面曲目起播：resolver 命中后回写队列', () async {
    final backend = FakePlaybackBackend();
    final facade = DefaultPlaybackFacade(backend: backend);
    var resolverCalls = 0;
    final provider = PlaybackProvider(
      facade: facade,
      messenger: FakeMessenger(),
      artworkResolver: (t) async {
        resolverCalls++;
        return 'https://img.example/${t.id.id}.jpg';
      },
    );
    addTearDown(provider.dispose);

    final item = track('a');
    backend.emit(BackendSnapshot(
      current: item,
      queue: [item],
      currentIndex: 0,
      isPlaying: true,
    ));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(resolverCalls, 1);
    expect(backend.lastArtworkTrackUri, 'fake:a');
    expect(backend.lastArtworkUri, 'https://img.example/a.jpg');
  });

  test('已有封面不触发补取', () async {
    final backend = FakePlaybackBackend();
    final facade = DefaultPlaybackFacade(backend: backend);
    var resolverCalls = 0;
    final provider = PlaybackProvider(
      facade: facade,
      messenger: FakeMessenger(),
      artworkResolver: (t) async {
        resolverCalls++;
        return 'https://img.example/x.jpg';
      },
    );
    addTearDown(provider.dispose);

    final item = track(
      'b',
      artwork: Artwork(uri: Uri.parse('https://img.example/existing.jpg')),
    );
    backend.emit(BackendSnapshot(
      current: item,
      queue: [item],
      currentIndex: 0,
      isPlaying: true,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(resolverCalls, 0);
    expect(backend.lastArtworkUri, isNull);
  });

  test('resolver 返回空 / 抛错：静默不影响播放', () async {
    final backend = FakePlaybackBackend();
    final facade = DefaultPlaybackFacade(backend: backend);
    final provider = PlaybackProvider(
      facade: facade,
      messenger: FakeMessenger(),
      artworkResolver: (t) async => throw StateError('boom'),
    );
    addTearDown(provider.dispose);

    final item = track('c');
    backend.emit(BackendSnapshot(
      current: item,
      queue: [item],
      currentIndex: 0,
      isPlaying: true,
    ));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(backend.lastArtworkUri, isNull);
    expect(provider.snapshot.current?.id.uri, 'fake:c');
  });
}
