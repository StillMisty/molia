import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/models/play_mode.dart';

import '../support/fakes.dart';

Track _track(String id) {
  return Track(
    id: TrackId('fake', id),
    title: 'Title $id',
    artists: [Artist(name: 'Artist $id')],
    album: 'Album',
    duration: const Duration(seconds: 30),
    origin: TrackOrigin.lx,
    payload: {'id': id},
  );
}

/// 默认播放模式（设置项）：持久化 + 启动时无曲目应用。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('默认 sequential：启动不额外下发 setMode', () async {
    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);

    await provider.preferencesReady;
    expect(provider.defaultPlayMode, PlayMode.sequential);
    expect(provider.currentMode, PlayMode.sequential);
    expect(backend.calls.where((call) => call == 'setMode'), isEmpty);
  });

  test('启动时加载持久化的 shuffle 并应用到 facade（无曲目）', () async {
    SharedPreferences.setMockInitialValues({'default_play_mode': 'shuffle'});
    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);

    await provider.preferencesReady;
    expect(provider.defaultPlayMode, PlayMode.shuffle);
    expect(provider.currentMode, PlayMode.shuffle);
    expect(backend.calls, contains('setMode'));
  });

  test('setDefaultPlayMode 持久化且无曲目时立即应用', () async {
    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    await provider.setDefaultPlayMode(PlayMode.singleRepeat);
    expect(provider.defaultPlayMode, PlayMode.singleRepeat);
    expect(provider.currentMode, PlayMode.singleRepeat);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('default_play_mode'), 'singleRepeat');
  });

  test('有曲目时不打断当前会话，仅持久化默认值', () async {
    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    // 当前正在播放（有曲目）时切换默认模式。
    final track = _track('a');
    backend.emit(BackendSnapshot(
      current: track,
      queue: [track],
      currentIndex: 0,
      isPlaying: true,
    ));
    await provider.setDefaultPlayMode(PlayMode.shuffle);

    expect(provider.defaultPlayMode, PlayMode.shuffle);
    expect(provider.currentMode, PlayMode.sequential);
    expect(backend.calls.where((call) => call == 'setMode'), isEmpty);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('default_play_mode'), 'shuffle');
  });
}
