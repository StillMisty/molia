import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/app/bootstrap/lyrics_stack.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/services/bili_account_service.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:molia/sources/source_manager.dart';

import '../support/fakes.dart';
import '../support/settings_test_support.dart';

/// 组合根接线：播放快照 → 歌词会话 ensureForTrack（页面未挂载也加载）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Track track(String id) => Track(
    id: TrackId('fake', id),
    title: 'Title $id',
    artists: const [Artist(name: 'Artist')],
    duration: const Duration(minutes: 3),
    origin: TrackOrigin.lx,
    payload: {'id': id},
  );

  Track biliTrack(String id) => Track(
    id: TrackId('bili', id),
    title: 'B 站 $id',
    artists: const [Artist(name: 'UP')],
    duration: const Duration(minutes: 3),
    origin: TrackOrigin.builtin,
    payload: {'bvid': id},
  );

  BackendSnapshot snapshot(Track current, {bool isPlaying = true}) =>
      BackendSnapshot(
        current: current,
        queue: [current],
        currentIndex: 0,
        isPlaying: isPlaying,
        position: const Duration(seconds: 10),
        duration: const Duration(minutes: 3),
      );

  test('播放快照换曲触发会话加载；同曲目快照抖动不重复取词', () async {
    SharedPreferences.setMockInitialValues({});
    final backend = FakePlaybackBackend();
    final playback = buildTestPlaybackProvider(backend: backend);
    addTearDown(playback.dispose);
    final service = _RecordingLyricsService();
    final lyrics = LyricsProvider(service: service);
    addTearDown(lyrics.dispose);

    wireLyricsSession(playback: playback, lyricsProvider: lyrics);
    expect(service.requested, isEmpty);

    final a = track('a');
    backend.emit(snapshot(a));
    await pumpEventQueue();
    expect(service.requested, ['fake:a']);
    expect(lyrics.state.status, LyricsStatus.ready);

    // 播放态变化（同一曲目）不重复取词。
    backend.emit(snapshot(a, isPlaying: false));
    await pumpEventQueue();
    expect(service.requested, ['fake:a']);

    // 播放通知有 50ms 节流：等过窗口再切曲。
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final b = track('b');
    backend.emit(snapshot(b));
    await pumpEventQueue();
    expect(service.requested, ['fake:a', 'fake:b']);
    expect(lyrics.state.trackId, 'fake:b');
  });

  test('B 站登录回调：清原生缓存并强刷当前 B 站歌词', () async {
    SharedPreferences.setMockInitialValues({});
    final service = _RecordingLyricsService();
    final lyrics = LyricsProvider(service: service);
    addTearDown(lyrics.dispose);
    final manager = SourceManager(settings: testSettingsRegistry());
    addTearDown(manager.dispose);
    final account = BiliAccountService(
      settings: testSettingsRegistry(keys: [kBiliAccountCookie])
          .scope([kBiliAccountCookie]),
    );
    addTearDown(account.dispose);
    await account.init();
    wireBiliLoginLyricsRefresh(
      account: account,
      sourceManager: manager,
      lyricsProvider: lyrics,
    );

    final track = biliTrack('BV1');
    await lyrics.load(track);
    expect(service.requested, ['bili:BV1']);

    account.onLoggedIn?.call();
    await pumpEventQueue();
    expect(service.requested, ['bili:BV1', 'bili:BV1']);
  });
}

class _RecordingLyricsService extends LyricsService {
  final List<String> requested = [];

  @override
  Future<LyricsResult?> getLyrics(
    String songName,
    String artistName,
    String trackId, {
    Track? track,
    bool ignoreCache = false,
  }) async {
    requested.add(trackId);
    return LyricsResult(lyric: '[00:01.00]$trackId', provider: 'fake');
  }
}
