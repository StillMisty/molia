import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:molia/domain/ports/music_source.dart' show PlayableStream;
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/audio_predownload.dart';
import 'package:molia/playback/audio_predownloader.dart';
import 'package:molia/playback/local_playback_service.dart';
import 'package:molia/playback/next_track_preloader.dart';
import 'package:molia/playback/playing_track_cache_writer.dart';
import 'package:molia/sources/source_track.dart';

/// 可脚本化播放器：只实现 [LocalPlaybackService] 用到的状态与控制接口，
/// 不触碰 just_audio 的平台通道。
class _FakeAudioPlayer extends AudioPlayer {
  final StreamController<PlayerState> _playerStates =
      StreamController<PlayerState>.broadcast();
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast();
  final StreamController<PlayerException> _errors =
      StreamController<PlayerException>.broadcast();

  /// 播放器收到的控制调用（断言顺序 / 是否被误暂停）。
  final List<String> calls = [];

  /// 最近一次设置的音频源：用来断言取链 headers 是否真的传到了播放器。
  AudioSource? lastAudioSource;

  /// 真正下发到平台的 play 次数。
  ///
  /// just_audio 在 `playing == true` 时 `play()` 会直接返回，不会把播放请求
  /// 交给平台；单测用它区分「调了 play」和「平台真的开始播」。
  int platformPlays = 0;

  bool _playing = false;
  ProcessingState _processingState = ProcessingState.idle;
  Duration _position = Duration.zero;
  Duration? _duration;

  @override
  bool get playing => _playing;

  @override
  ProcessingState get processingState => _processingState;

  @override
  Duration get position => _position;

  @override
  Duration? get duration => _duration;

  @override
  Stream<PlayerState> get playerStateStream => _playerStates.stream;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Stream<PlayerException> get errorStream => _errors.stream;

  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    calls.add('setAudioSource');
    lastAudioSource = audioSource;
    _processingState = ProcessingState.ready;
    _position = Duration.zero;
    _duration ??= const Duration(seconds: 30);
    return _duration;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    // 与 just_audio 一致：已在播放请求态时直接返回，不会再次下发平台 play。
    if (_playing) return;
    platformPlays++;
    emitState(true, _processingState);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    if (!_playing) return;
    emitState(false, _processingState);
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    calls.add('seek:${position?.inMilliseconds ?? 0}');
    _position = position ?? Duration.zero;
    if (_processingState == ProcessingState.completed) {
      _processingState = ProcessingState.ready;
    }
    emitState(_playing, _processingState);
    _positions.add(_position);
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {
    calls.add('stop');
    emitState(false, ProcessingState.idle);
  }

  @override
  Future<void> dispose() async {
    await _playerStates.close();
    await _positions.close();
    await _errors.close();
  }

  /// 模拟自然播完：just_audio 的 playing 在 completed 后仍保持 true。
  void complete() {
    _position = _duration ?? Duration.zero;
    emitState(true, ProcessingState.completed);
  }

  /// 模拟在曲末暂停：media_kit 停在 EOF 时可能只发 ready + 曲末位置，
  /// 不会上报 completed。
  void pauseAtEnd() {
    _position = _duration ?? Duration.zero;
    emitState(false, ProcessingState.ready);
  }

  /// 模拟播放中错误（如曲末 FLAC 尾帧损坏时的 `Error decoding audio`）。
  void fail(String message) {
    _errors.add(PlayerException(1, message, null));
  }

  /// 模拟 just_audio 在曲末重复采样：playing 仍为 true、状态 ready，
  /// 位置被插值钳在时长上（Windows/Linux media_kit 不上报 completed 的场景）。
  void emitPosition(Duration position) {
    _position = position;
    _positions.add(position);
  }

  /// 模拟 just_audio 在 completed 后仍保持 playing=true 的内部请求态
  /// （不产生平台事件）。
  void forcePlayingFlag(bool playing) => _playing = playing;

  void emitState(bool playing, ProcessingState processingState) {
    _playing = playing;
    _processingState = processingState;
    _playerStates.add(PlayerState(playing, processingState));
  }
}

SourceTrack _track({int index = 0}) => SourceTrack(
      sourceKey: 'test',
      origin: 'builtin',
      title: '测试曲目$index',
      artist: '测试歌手',
      album: '',
      duration: const Duration(seconds: 30),
      raw: {'id': 'a$index'},
    );

/// 记录预取调用：任务永不完成，取消时记录曲目 id。
class _TaskPredownloader implements AudioPredownloader {
  final List<SourceTrack> calls = [];
  final List<String> cancelled = [];

  @override
  Future<AudioPredownloadTask?> predownload({
    required SourceTrack track,
    required PlayableStream stream,
    String? quality,
  }) async {
    calls.add(track);
    return AudioPredownloadTask(
      done: Completer<void>().future,
      onCancel: () => cancelled.add(track.id),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 关掉边播边缓存 / audio_session 插件路径，单测只走假播放器。
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  Future<({LocalPlaybackService service, _FakeAudioPlayer player})> start({
    PlayMode mode = PlayMode.listLoop,
    int trackCount = 1,
  }) async {
    final player = _FakeAudioPlayer();
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async =>
          PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
      player: player,
    );
    addTearDown(service.dispose);
    await service.setMode(mode);
    await service.playTracks(
      [for (var i = 0; i < trackCount; i++) _track(index: i)],
      0,
    );
    await pumpEventQueue();
    expect(service.isPlaying, isTrue);
    return (service: service, player: player);
  }

  test('顺序播放队尾自然播完后，底层播放器被显式暂停', () async {
    final (:service, :player) = await start(mode: PlayMode.sequential);

    player.complete();
    await pumpEventQueue();

    expect(service.isPlaying, isFalse);
    expect(player.playing, isFalse, reason: '不能只改 UI 状态，底层要真正暂停');
    expect(player.calls, contains('pause'));
    expect(service.position, const Duration(seconds: 30));
  });

  test('曲末暂停后第一次点播放从 0 重播，而不是被当成暂停', () async {
    final (:service, :player) = await start(mode: PlayMode.sequential);
    player.complete();
    await pumpEventQueue();

    player.calls.clear();
    await service.toggle();
    await pumpEventQueue();

    expect(player.calls, contains('seek:0'));
    expect(player.calls, contains('play'));
    expect(player.calls, isNot(contains('pause')));
    expect(service.isPlaying, isTrue);
  });

  test('media_kit 暂停在 EOF（ready + 曲末位置）时，点播放从 0 重播', () async {
    final (:service, :player) = await start();

    // 暂停在最后一刻：位置已到曲末，但没有 completed 事件。
    player.pauseAtEnd();
    await pumpEventQueue();
    expect(service.isPlaying, isFalse);
    expect(player.processingState, ProcessingState.ready);

    player.calls.clear();
    await service.toggle();
    await pumpEventQueue();

    expect(player.calls, contains('seek:0'));
    expect(player.calls, contains('play'));
    expect(service.isPlaying, isTrue);
  });

  test('列表循环单曲自然播完后从 0 重播，且平台 play 真正下发', () async {
    final (:service, :player) = await start();
    final playsBefore = player.platformPlays;

    player.complete();
    await pumpEventQueue();

    expect(player.calls, contains('seek:0'));
    expect(player.platformPlays, playsBefore + 1,
        reason: 'playing 仍为 true 时直接 play() 不会下发平台请求，必须先前置暂停');
    expect(service.isPlaying, isTrue);
    expect(service.position, Duration.zero);
  });

  test('completed 但底层 playing 仍为 true 时，点播放先暂停再下发 play', () async {
    final (:service, :player) = await start(mode: PlayMode.sequential);
    player.complete();
    await pumpEventQueue();
    // just_audio 的契约：播完后 playing 仍为 true；模拟完成回调已把 UI 置停。
    player.forcePlayingFlag(true);
    final playsBefore = player.platformPlays;

    player.calls.clear();
    await service.toggle();
    await pumpEventQueue();

    expect(player.calls, contains('pause'));
    expect(player.calls, contains('seek:0'));
    expect(player.calls, contains('play'));
    expect(player.platformPlays, playsBefore + 1);
    expect(service.isPlaying, isTrue);
  });

  test('正常播放中点播放是暂停，不触发 seek', () async {
    final (:service, :player) = await start();

    player.calls.clear();
    await service.toggle();
    await pumpEventQueue();

    expect(player.calls, contains('pause'));
    expect(player.calls, isNot(contains('seek:0')));
    expect(service.isPlaying, isFalse);
  });

  test('播完后重复的 completed 状态只上报一次完成事件', () async {
    final (:service, :player) = await start(mode: PlayMode.sequential);
    final completions = <String>[];
    final subscription = service.trackCompletions.listen(
      (track) => completions.add(track.id),
    );
    addTearDown(subscription.cancel);

    player.complete();
    await pumpEventQueue();
    expect(completions, hasLength(1));

    player.calls.clear();
    // 暂停 / seek 会再次上报 (playing=false, completed)：按状态跳变去重。
    player.emitState(false, ProcessingState.completed);
    await pumpEventQueue();

    expect(completions, hasLength(1));
    expect(player.calls, isEmpty);
  });

  test('media_kit 未上报 completed 时，曲末位置兜底自动切到下一首', () async {
    final (:service, :player) = await start(trackCount: 2);
    final completions = <String>[];
    final subscription = service.trackCompletions.listen(
      (track) => completions.add(track.id),
    );
    addTearDown(subscription.cancel);
    player.calls.clear();
    final playsBefore = player.platformPlays;

    // 自然播完：playing 仍为 true、状态 ready，位置钳在时长上。
    player.emitPosition(const Duration(seconds: 30));
    player.emitPosition(const Duration(seconds: 30));
    await pumpEventQueue();

    expect(completions, hasLength(1), reason: '兜底只上报一次完成事件');
    expect(service.currentIndex, 1);
    expect(service.isPlaying, isTrue);
    expect(service.position, Duration.zero);
    expect(
      player.calls,
      ['pause', 'setAudioSource', 'play'],
      reason: '自动切歌前先暂停，下一首的 play 必须真正下发到平台',
    );
    expect(player.platformPlays, playsBefore + 1);
  });

  test('曲末前 250ms 内位置仍在前进时不会提前切歌', () async {
    final (:service, :player) = await start(trackCount: 2);

    player.emitPosition(
      const Duration(seconds: 30) - const Duration(milliseconds: 200),
    );
    player.emitPosition(
      const Duration(seconds: 30) - const Duration(milliseconds: 100),
    );
    await pumpEventQueue();

    expect(service.currentIndex, 0);
    expect(service.isPlaying, isTrue);
  });

  test('曲末兜底按曲目重新武装，不会连跳两首', () async {
    final (:service, :player) = await start(trackCount: 3);

    player.emitPosition(const Duration(seconds: 30));
    player.emitPosition(const Duration(seconds: 30));
    await pumpEventQueue();
    expect(service.currentIndex, 1);

    player.emitPosition(const Duration(seconds: 30));
    player.emitPosition(const Duration(seconds: 30));
    await pumpEventQueue();
    expect(service.currentIndex, 2);
  });

  test('用户暂停在曲末不会被曲末兜底误判成播完', () async {
    final (:service, :player) = await start(trackCount: 2);

    player.pauseAtEnd();
    await pumpEventQueue();
    player.emitPosition(const Duration(seconds: 30));
    player.emitPosition(const Duration(seconds: 30));
    await pumpEventQueue();

    expect(service.currentIndex, 0);
    expect(service.isPlaying, isFalse);
  });

  test('用户从曲末拖回开头不会被曲末兜底误判成播完', () async {
    final (:service, :player) = await start(trackCount: 2);

    player.emitPosition(const Duration(seconds: 30));
    await pumpEventQueue();
    await service.seek(Duration.zero);
    await pumpEventQueue();

    expect(service.currentIndex, 0);
    expect(service.isPlaying, isTrue);
  });

  test('顺序播放队尾曲末兜底只停在曲末，不自动切歌', () async {
    final (:service, :player) = await start(mode: PlayMode.sequential);

    player.emitPosition(const Duration(seconds: 30));
    player.emitPosition(const Duration(seconds: 30));
    await pumpEventQueue();

    expect(service.currentIndex, 0);
    expect(service.isPlaying, isFalse);
    expect(player.playing, isFalse);
    expect(service.position, const Duration(seconds: 30));
  });

  test('Android 不使用桌面曲末兜底', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final (:service, :player) = await start(trackCount: 2);

    player.emitPosition(const Duration(seconds: 30));
    player.emitPosition(const Duration(seconds: 30));
    await pumpEventQueue();

    expect(service.currentIndex, 0);
    expect(service.isPlaying, isTrue);
  });

  test('曲末解码失败按自然播完处理并自动切歌', () async {
    final (:service, :player) = await start(trackCount: 2);
    final completions = <String>[];
    final subscription = service.trackCompletions.listen(
      (track) => completions.add(track.id),
    );
    addTearDown(subscription.cancel);

    // tx / kw 的 FLAC 尾帧损坏：mpv 在距曲末几百毫秒处报解码错误，
    // processingState 直接 idle，completed 不会到达。
    player.emitPosition(const Duration(seconds: 29, milliseconds: 700));
    await pumpEventQueue();
    player.fail('Error decoding audio');
    await pumpEventQueue();

    expect(completions, hasLength(1));
    expect(service.currentIndex, 1);
    expect(service.isPlaying, isTrue);
    expect(service.lastError, isNull, reason: '曲末错误按播完处理，不展示为播放失败');
  });

  test('非曲末的播放错误仍上报失败，不自动切歌', () async {
    final (:service, :player) = await start(trackCount: 2);

    player.emitPosition(const Duration(seconds: 5));
    await pumpEventQueue();
    player.fail('Error decoding audio');
    await pumpEventQueue();

    expect(service.currentIndex, 0);
    expect(service.isPlaying, isFalse);
    expect(service.lastError, contains('Error decoding audio'));
  });

  test('顺序播放队尾曲末解码失败停在曲末', () async {
    final (:service, :player) = await start(mode: PlayMode.sequential);

    player.emitPosition(const Duration(seconds: 29, milliseconds: 800));
    await pumpEventQueue();
    player.fail('Error decoding audio');
    await pumpEventQueue();

    expect(service.currentIndex, 0);
    expect(service.isPlaying, isFalse);
    expect(service.position, const Duration(seconds: 30));
  });

  test('Android 曲末解码错误仍按错误上报，不做桌面兜底', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final (:service, :player) = await start(trackCount: 2);

    player.emitPosition(const Duration(seconds: 29, milliseconds: 800));
    await pumpEventQueue();
    player.fail('Error decoding audio');
    await pumpEventQueue();

    expect(service.currentIndex, 0);
    expect(service.isPlaying, isFalse);
    expect(service.lastError, contains('Error decoding audio'));
  });

  test('取链 headers 透传到 AudioSource（B 站直链依赖 Referer）', () async {
    const headers = {
      'Referer': 'https://www.bilibili.com/',
      'User-Agent': 'Mozilla/5.0',
    };
    final player = _FakeAudioPlayer();
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async => PlayableStream(
        Uri.parse('https://cdn.example/a.m4a'),
        headers: headers,
      ),
      player: player,
    );
    addTearDown(service.dispose);

    await service.playTracks([_track()], 0);
    await pumpEventQueue();

    final source = player.lastAudioSource;
    expect(source, isA<UriAudioSource>());
    expect((source! as UriAudioSource).headers, headers);
  });

  test('桌面切到正在预取的下一首：复用在途任务，不另起 writer 重下', () async {
    final predownloader = _TaskPredownloader();
    final preloader = NextTrackPreloader(
      resolver: (track, {String? quality}) async => PlayableStream(
        Uri.parse('https://cdn.example/${track.id}.mp3'),
      ),
      predownloader: predownloader,
    );
    final player = _FakeAudioPlayer();
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async => PlayableStream(
        Uri.parse('https://cdn.example/${track.id}.mp3'),
      ),
      player: player,
      nextTrackPreloader: preloader,
      audioCacheWriter: PlayingTrackCacheWriter(predownloader: predownloader),
    );
    addTearDown(service.dispose);

    final tracks = [_track(index: 0), _track(index: 1)];
    await service.playTracks(tracks, 0);
    await pumpEventQueue();
    expect(preloader.isCacheWriteInFlight(tracks[1]), isTrue,
        reason: '起播 A 后应开始预取 B');

    await service.playQueueIndex(1);
    await pumpEventQueue();

    expect(
      predownloader.calls.where((track) => track.id == tracks[1].id),
      hasLength(1),
      reason: 'B 的写入由在途预取负责，不能再起 writer 重下同一首',
    );
    expect(predownloader.cancelled, isNot(contains(tracks[1].id)));
  });
}
