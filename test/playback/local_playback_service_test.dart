import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/local_playback_service.dart';
import 'package:molia/sources/source_track.dart';

/// 可脚本化播放器：只实现 [LocalPlaybackService] 用到的状态与控制接口，
/// 不触碰 just_audio 的平台通道。
class _FakeAudioPlayer extends AudioPlayer {
  final StreamController<PlayerState> _playerStates =
      StreamController<PlayerState>.broadcast();
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast();

  /// 播放器收到的控制调用（断言顺序 / 是否被误暂停）。
  final List<String> calls = [];

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
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    calls.add('setAudioSource');
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

  /// 模拟 just_audio 在 completed 后仍保持 playing=true 的内部请求态
  /// （不产生平台事件）。
  void forcePlayingFlag(bool playing) => _playing = playing;

  void emitState(bool playing, ProcessingState processingState) {
    _playing = playing;
    _processingState = processingState;
    _playerStates.add(PlayerState(playing, processingState));
  }
}

SourceTrack _track() => const SourceTrack(
      sourceKey: 'test',
      origin: 'builtin',
      title: '测试曲目',
      artist: '测试歌手',
      album: '',
      duration: Duration(seconds: 30),
      raw: {'id': 'a'},
    );

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
  }) async {
    final player = _FakeAudioPlayer();
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async =>
          'file:///tmp/molia-test.mp3',
      player: player,
    );
    addTearDown(service.dispose);
    await service.setMode(mode);
    await service.playTracks([_track()], 0);
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
}
