import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:molia/domain/ports/music_source.dart' show PlayableStream;
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/play_mode.dart';
import 'package:molia/playback/audio_predownload.dart';
import 'package:molia/playback/audio_predownloader.dart';
import 'package:molia/playback/audio_cache_completion_recorder.dart';
import 'package:molia/playback/audio_cache_source.dart';
import 'package:molia/playback/audio_cache_writer_registry.dart';
import 'package:molia/playback/audio_session_lifecycle.dart';
import 'package:molia/playback/local_playback_service.dart';
import 'package:molia/playback/next_track_preloader.dart';
import 'package:molia/playback/playing_track_cache_writer.dart';
import 'package:molia/sources/source_track.dart';
import 'package:molia/services/audio_cache_store.dart';
import 'package:molia/services/cache_service.dart';
import 'package:path/path.dart' as p;

import '../support/fake_platform_audio_port.dart';

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
  double _volume = 1.0;

  /// 模拟平台拒绝 play（坏源 / 后端错误），下一次 play 抛错。
  bool failPlay = false;

  /// 下一次 `setAudioSource` 解析出的时长（模拟换源后更短的音频）；用完即清。
  Duration? nextSourceDuration;

  /// 平台收到的音量写入（按顺序）：淡变 / 音量 / 静音断言用。
  final List<double> volumeCalls = [];

  @override
  bool get playing => _playing;

  @override
  double get volume => _volume;

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
    // 换源可以解析出不同时长（失败恢复后新源更短的场景）。
    final nextDuration = nextSourceDuration;
    nextSourceDuration = null;
    _duration = nextDuration ?? (_duration ?? const Duration(seconds: 30));
    return _duration;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    if (failPlay) {
      failPlay = false;
      throw StateError('play failed');
    }
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
  Future<void> setVolume(double volume) async {
    _volume = volume;
    volumeCalls.add(volume);
  }

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

SourceTrack _track({int index = 0, List<SourceQuality> qualities = const []}) =>
    SourceTrack(
      sourceKey: 'test',
      origin: 'builtin',
      title: '测试曲目$index',
      artist: '测试歌手',
      album: '',
      duration: const Duration(seconds: 30),
      qualities: qualities,
      raw: {'id': 'a$index'},
    );

const List<SourceQuality> _switchableQualities = [
  SourceQuality(type: '320k'),
  SourceQuality(type: 'flac'),
  SourceQuality(type: '128k'),
];

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
    // 既有用例不测淡变：关闭可避免每个 pause 都等一个真实淡变窗口。
    Duration fadeDuration = Duration.zero,
  }) async {
    final player = _FakeAudioPlayer();
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async =>
          PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
      player: player,
      fadeDuration: fadeDuration,
    );
    addTearDown(service.dispose);
    await service.setMode(mode);
    await service.playTracks([
      for (var i = 0; i < trackCount; i++) _track(index: i),
    ], 0);
    await pumpEventQueue();
    expect(service.isPlaying, isTrue);
    return (service: service, player: player);
  }

  /// 带真实生命周期 + 假端口的服务（Android 混播策略，不触碰平台通道）。
  Future<
    ({
      LocalPlaybackService service,
      _FakeAudioPlayer player,
      FakePlatformAudioPort port,
      ValueNotifier<bool> settings,
    })
  >
  startSession({
    Duration fadeDuration = Duration.zero,
    Duration activationWait = AudioSessionLifecycle.defaultActivationWait,
    Duration pauseGrace = AudioSessionLifecycle.defaultPauseGrace,
    bool playWithOtherApps = true,
    void Function()? onActivate,
    bool failFirstPlay = false,
    bool sessionSupported = true,
  }) async {
    final player = _FakeAudioPlayer()..failPlay = failFirstPlay;
    final port = FakePlatformAudioPort(supported: sessionSupported)
      ..onActivate = onActivate;
    final settings = ValueNotifier<bool>(playWithOtherApps);
    final lifecycle = AudioSessionLifecycle(
      port: port,
      playWithOtherApps: settings,
      platform: TargetPlatform.android,
      activationWait: activationWait,
      pauseGrace: pauseGrace,
    );
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async =>
          PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
      player: player,
      fadeDuration: fadeDuration,
      audioSession: lifecycle,
      playWithOtherApps: settings,
    );
    addTearDown(service.dispose);
    addTearDown(settings.dispose);
    addTearDown(port.dispose);
    await service.playTracks([_track(index: 0)], 0);
    await pumpEventQueue();
    return (service: service, player: player, port: port, settings: settings);
  }

  test('起播先激活会话、激活早于播放器 play；停止才释放', () async {
    final player = _FakeAudioPlayer();
    final port = FakePlatformAudioPort();
    final settings = ValueNotifier<bool>(true);
    final lifecycle = AudioSessionLifecycle(
      port: port,
      playWithOtherApps: settings,
      platform: TargetPlatform.android,
    );
    port.onActivate = () {
      expect(player.calls, isNot(contains('play')), reason: '必须先激活再 play');
    };
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async =>
          PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
      player: player,
      fadeDuration: Duration.zero,
      audioSession: lifecycle,
      playWithOtherApps: settings,
    );
    addTearDown(service.dispose);
    addTearDown(settings.dispose);

    await service.playTracks([_track(index: 0)], 0);
    await pumpEventQueue();

    expect(port.calls, ['start', 'configure', 'activate']);
    expect(port.activateCalls, 1);
    expect(player.platformPlays, 1);

    await service.pause();
    expect(port.deactivateCalls, 0, reason: '暂停后仍在 20 秒宽限期内');

    await service.stop();
    expect(port.deactivateCalls, 1);
    expect(port.deactivateNotifyOthers, [true]);
    expect(player.calls.last, 'stop');
  });

  test('宽限内续播与切歌复用已激活会话，不重复激活 / 不提前释放', () async {
    final ctx = await startSession();
    await ctx.service.pause();
    await pumpEventQueue();
    expect(ctx.port.deactivateCalls, 0);

    await ctx.service.play();
    await pumpEventQueue();
    // 队列只有一首：列表循环的下一首就是自己，仍走同一条起播路径。
    await ctx.service.skipToNext();
    await pumpEventQueue();

    expect(ctx.port.activateCalls, 1);
    expect(ctx.port.deactivateCalls, 0);
    expect(ctx.service.isPlaying, isTrue);
  });

  test('退出收尾释放会话（notify-others）且只释放一次', () async {
    final ctx = await startSession();
    await ctx.service.shutdownAudioForQuit();
    await ctx.service.shutdownAudioForQuit();

    expect(ctx.port.deactivateCalls, 1);
    expect(ctx.port.deactivateNotifyOthers, [true]);
  });

  test('激活被拒：不起播、上报可重试失败', () async {
    final player = _FakeAudioPlayer();
    final port = FakePlatformAudioPort()..activateResults.add(false);
    final settings = ValueNotifier<bool>(true);
    final lifecycle = AudioSessionLifecycle(
      port: port,
      playWithOtherApps: settings,
      platform: TargetPlatform.android,
      activationWait: const Duration(milliseconds: 20),
    );
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async =>
          PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
      player: player,
      fadeDuration: Duration.zero,
      audioSession: lifecycle,
      playWithOtherApps: settings,
    );
    addTearDown(service.dispose);
    addTearDown(settings.dispose);

    await service.playTracks([_track(index: 0)], 0);
    await pumpEventQueue();

    expect(player.platformPlays, 0);
    expect(service.isPlaying, isFalse);
    final error = service.lastError;
    expect(error, isA<SourceFailure>());
    expect((error as SourceFailure).retryable, isTrue);
  });

  test('起播被拒后中断结束重试成功：保留播放意图并可继续控制', () async {
    final player = _FakeAudioPlayer();
    final port = FakePlatformAudioPort()..activateResults.addAll([false, true]);
    final settings = ValueNotifier<bool>(true);
    final lifecycle = AudioSessionLifecycle(
      port: port,
      playWithOtherApps: settings,
      platform: TargetPlatform.android,
    );
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async =>
          PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
      player: player,
      fadeDuration: Duration.zero,
      audioSession: lifecycle,
      playWithOtherApps: settings,
    );
    addTearDown(service.dispose);
    addTearDown(settings.dispose);

    final play = service.playTracks([_track(index: 0)], 0);
    await pumpEventQueue();
    expect(player.platformPlays, 0, reason: '焦点被拒时不能起播');

    port.emitInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    await play;
    await pumpEventQueue();

    expect(port.activateCalls, 2);
    expect(service.isPlaying, isTrue);
    expect(player.platformPlays, 1);
    // 原地重取链按 `_wantsPlayback` 决定是否继续出声：延迟授权必须保留
    // 「用户要播」的意图，否则重取后会停在暂停态。
    await service.reloadCurrentStream();
    await pumpEventQueue();
    expect(service.isPlaying, isTrue);
    // 暂停 / 再播仍按正常路径工作。
    expect(await service.pause(), isTrue);
    await service.play();
    await pumpEventQueue();
    expect(service.isPlaying, isTrue);
    expect(player.platformPlays, 2);
  });

  test('play() 失败：上报暂停，宽限后释放会话', () async {
    final ctx = await startSession(
      pauseGrace: const Duration(milliseconds: 20),
      failFirstPlay: true,
    );
    await pumpEventQueue();

    expect(ctx.service.isPlaying, isFalse);
    expect(ctx.port.deactivateCalls, 0, reason: '失败后先给宽限期，不立即释放');

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(ctx.port.deactivateCalls, 1);
    expect(ctx.port.deactivateNotifyOthers, [true]);
  });

  test('duck 压低到基值 × 0.2，结束后恢复；中途改音量 / 静音都保留', () async {
    final ctx = await startSession();
    final player = ctx.player;
    final port = ctx.port;

    port.emitInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.duck),
    );
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(player.volumeCalls.last, closeTo(0.2, 0.01));

    await ctx.service.setVolume(0.5);
    expect(player.volumeCalls.last, closeTo(0.1, 0.01));

    port.emitInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.duck),
    );
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(player.volumeCalls.last, closeTo(0.5, 0.001));

    // duck 中静音：恢复后仍是静音，不跳回旧值。
    port.emitInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.duck),
    );
    await Future<void>.delayed(const Duration(milliseconds: 140));
    await ctx.service.setVolume(0);
    port.emitInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.duck),
    );
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(player.volumeCalls.last, 0);
  });

  test('暂停 / 停止中的 duck 被忽略；暂停会复位 duck', () async {
    final ctx = await startSession();
    final player = ctx.player;
    final port = ctx.port;

    port.emitInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.duck),
    );
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(player.volumeCalls.last, closeTo(0.2, 0.01));

    await ctx.service.pause(urgent: true);
    expect(player.volumeCalls.last, closeTo(1.0, 0.001), reason: '暂停复位 duck');

    final before = player.volumeCalls.length;
    port.emitInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.duck),
    );
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(player.volumeCalls.length, before, reason: '暂停中不压低');
  });

  test('淡变中收到 duck：压低与包络相乘，不重置淡变', () async {
    final ctx = await startSession(fadeDuration: const Duration(seconds: 1));
    final player = ctx.player;
    final port = ctx.port;

    port.emitInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.duck),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(ctx.service.envelopeGain, lessThan(1.0));
    expect(ctx.service.envelopeGain, greaterThan(0.0));
    expect(
      player.volumeCalls.last,
      lessThan(0.2),
      reason: '基值 × 未完成的包络 × 0.2，不能先回到满音量',
    );

    port.emitInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.duck),
    );
    await ctx.service.stop();
  });

  test('换队列 / 显式停止时回收播放器，清空 just_audio source 注册表', () async {
    final players = <_FakeAudioPlayer>[];
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async =>
          PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
      playerFactory: () {
        final player = _FakeAudioPlayer();
        players.add(player);
        return player;
      },
    );
    addTearDown(service.dispose);

    await service.playTracks([_track(index: 0)], 0);
    await pumpEventQueue();
    expect(players, hasLength(1));

    await service.playTracks([_track(index: 1)], 0);
    await pumpEventQueue();
    expect(players, hasLength(2), reason: '旧队列的 source 注册表应随播放器回收');
    expect(service.isPlaying, isTrue);

    // 显式 stop(clear) 再换一次；暂停语义的 stop(clear:false) 不换。
    await service.stop();
    expect(players, hasLength(3));
  });

  test('暂停托盘释放播放器，恢复播放按保存进度重载', () async {
    final players = <_FakeAudioPlayer>[];
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async =>
          PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
      playerFactory: () {
        final player = _FakeAudioPlayer();
        players.add(player);
        return player;
      },
    );
    addTearDown(service.dispose);

    await service.playTracks([_track(index: 0)], 0);
    await pumpEventQueue();
    await service.seek(const Duration(seconds: 7));
    await service.pause();
    await pumpEventQueue();
    expect(players, hasLength(1));

    await service.releasePlayerForIdle();
    expect(players, hasLength(2), reason: '暂停托盘回收旧 player / source');
    expect(service.isPlaying, isFalse);
    expect(service.currentSourceTrack, isNotNull);

    await service.toggle();
    await pumpEventQueue();
    expect(service.isPlaying, isTrue);
    expect(players, hasLength(2), reason: '恢复播放复用新 player');
    expect(players.last.calls, contains('setAudioSource'));
    expect(players.last.calls, contains('seek:7000'), reason: '按保存进度重载');
  });

  test('顺序播放队尾自然播完后，底层播放器被显式暂停', () async {
    final (:service, :player) = await start(mode: PlayMode.sequential);

    player.complete();
    await pumpEventQueue();

    expect(service.isPlaying, isFalse);
    expect(player.playing, isFalse, reason: '不能只改 UI 状态，底层要真正暂停');
    expect(player.calls, contains('pause'));
    expect(service.position, const Duration(seconds: 30));
  });

  test('手动切歌：先暂停卸载旧源，再取链与加载新源', () async {
    final player = _FakeAudioPlayer();
    final tracks = [_track(index: 0), _track(index: 1)];
    var stoppedBeforeResolve = false;
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async {
        if (track.id == tracks[1].id) {
          stoppedBeforeResolve = player.calls.contains('stop');
        }
        return PlayableStream(Uri.parse('file:///tmp/molia-test.mp3'));
      },
      player: player,
    );
    addTearDown(service.dispose);

    await service.playTracks(tracks, 0);
    await pumpEventQueue();
    expect(service.isPlaying, isTrue);

    player.calls.clear();
    await service.skipToNext();
    await pumpEventQueue();

    expect(stoppedBeforeResolve, isTrue, reason: '取链前旧源必须已停止');
    expect(player.calls, ['stop', 'setAudioSource', 'play']);
    expect(service.currentIndex, 1);
    expect(service.isPlaying, isTrue);
  });

  test('切歌装载期间点播放：不会把停掉的旧源重新拉起来', () async {
    final player = _FakeAudioPlayer();
    final tracks = [_track(index: 0), _track(index: 1)];
    Completer<PlayableStream>? pending;
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) {
        if (track.id == tracks[1].id) {
          pending = Completer<PlayableStream>();
          return pending!.future;
        }
        return Future.value(
          PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
        );
      },
      player: player,
    );
    addTearDown(service.dispose);

    await service.playTracks(tracks, 0);
    await pumpEventQueue();

    final switching = service.skipToNext();
    await pumpEventQueue();
    expect(service.isLoading, isTrue, reason: '新源尚未落位');
    expect(service.isPlaying, isFalse);
    expect(player.calls, contains('stop'));
    expect(pending, isNotNull);

    // 装载空窗里点播放：不能直接 play() 旧源。
    player.calls.clear();
    await service.toggle();
    expect(player.calls, isEmpty);

    pending!.complete(PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')));
    await switching;
    await pumpEventQueue();

    expect(service.currentIndex, 1);
    expect(service.isPlaying, isTrue);
    expect(player.calls, contains('setAudioSource'));
    expect(player.calls, contains('play'));
  });

  test('切歌取链失败后点播放：按当前曲目重新装载，不恢复旧源', () async {
    final player = _FakeAudioPlayer();
    final tracks = [_track(index: 0), _track(index: 1)];
    var failNext = true;
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async {
        if (failNext && track.id == tracks[1].id) {
          failNext = false;
          throw StateError('取链失败');
        }
        return PlayableStream(Uri.parse('file:///tmp/molia-test.mp3'));
      },
      player: player,
    );
    addTearDown(service.dispose);

    await service.playTracks(tracks, 0);
    await pumpEventQueue();

    player.calls.clear();
    await service.skipToNext();
    await pumpEventQueue();
    expect(service.currentIndex, 1);
    expect(service.isPlaying, isFalse);
    expect(service.lastError, isNotNull);
    expect(player.calls, ['stop'], reason: '取链失败时不能继续加载 / 播放');

    player.calls.clear();
    await service.toggle();
    await pumpEventQueue();

    expect(player.calls, ['setAudioSource', 'play']);
    expect(service.currentIndex, 1);
    expect(service.isPlaying, isTrue);
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

  test('切换音质：暂停中保持进度与暂停态，同一档位不重复取链', () async {
    final requested = <String?>[];
    final player = _FakeAudioPlayer();
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async {
        requested.add(quality);
        return PlayableStream(Uri.parse('file:///tmp/molia-test.mp3'));
      },
      player: player,
      preferredQuality: () => '320k',
    );
    addTearDown(service.dispose);
    await service.playTracks([_track(qualities: _switchableQualities)], 0);
    await pumpEventQueue();
    await service.seek(const Duration(seconds: 10));
    await service.pause();
    await pumpEventQueue();
    expect(service.isPlaying, isFalse);

    final callsBefore = requested.length;
    await service.setCurrentQuality('320k');
    expect(requested.length, callsBefore, reason: '同一档位不重新取链');

    player.calls.clear();
    await service.setCurrentQuality('flac');
    await pumpEventQueue();

    expect(requested.last, 'flac');
    expect(service.currentQuality, 'flac');
    expect(player.calls, contains('seek:10000'));
    expect(player.calls.where((call) => call == 'play'), isEmpty);
    expect(service.position, const Duration(seconds: 10));
    expect(service.isPlaying, isFalse);
  });

  test('切换音质：播放中保持播放态并从原进度继续', () async {
    final requested = <String?>[];
    final player = _FakeAudioPlayer();
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async {
        requested.add(quality);
        return PlayableStream(Uri.parse('file:///tmp/molia-test.mp3'));
      },
      player: player,
      preferredQuality: () => '320k',
    );
    addTearDown(service.dispose);
    await service.playTracks([_track(qualities: _switchableQualities)], 0);
    await pumpEventQueue();
    await service.seek(const Duration(seconds: 10));
    await pumpEventQueue();
    expect(service.isPlaying, isTrue);

    player.calls.clear();
    await service.setCurrentQuality('128k');
    await pumpEventQueue();

    expect(requested.last, '128k');
    expect(service.currentQuality, '128k');
    expect(player.calls, contains('seek:10000'));
    expect(player.calls, contains('play'));
    expect(player.calls, isNot(contains('stop')), reason: '音质切换保持进度，不能卸载播放器');
    expect(service.position, const Duration(seconds: 10));
    expect(service.isPlaying, isTrue);
  });

  group('播放失败原地重取', () {
    test('播放中：按当前进度重新取链并继续播放', () async {
      final requested = <String?>[];
      final player = _FakeAudioPlayer();
      final service = LocalPlaybackService(
        resolver: (track, {String? quality}) async {
          requested.add(quality);
          return PlayableStream(Uri.parse('file:///tmp/molia-test.mp3'));
        },
        player: player,
      );
      addTearDown(service.dispose);
      await service.playTracks([_track()], 0);
      await pumpEventQueue();
      await service.seek(const Duration(seconds: 12));
      await pumpEventQueue();
      final resolvesBefore = requested.length;

      player.calls.clear();
      await service.reloadCurrentStream();
      await pumpEventQueue();

      expect(requested.length, resolvesBefore + 1, reason: '原地重取 = 再取一次链');
      expect(player.calls, contains('setAudioSource'));
      expect(player.calls, contains('seek:12000'));
      expect(player.calls, contains('play'));
      expect(player.calls, isNot(contains('stop')), reason: '不卸载旧源，也不切歌');
      expect(service.position, const Duration(seconds: 12));
      expect(service.isPlaying, isTrue);
      expect(service.currentIndex, 0);
    });

    test('暂停中：保留进度，不自动起播', () async {
      final player = _FakeAudioPlayer();
      final service = LocalPlaybackService(
        resolver: (track, {String? quality}) async =>
            PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
        player: player,
      );
      addTearDown(service.dispose);
      await service.playTracks([_track()], 0);
      await pumpEventQueue();
      await service.seek(const Duration(seconds: 10));
      await service.pause();
      await pumpEventQueue();
      expect(service.isPlaying, isFalse);

      player.calls.clear();
      await service.reloadCurrentStream();
      await pumpEventQueue();

      expect(player.calls, contains('seek:10000'));
      expect(player.calls.where((call) => call == 'play'), isEmpty);
      expect(service.position, const Duration(seconds: 10));
      expect(service.isPlaying, isFalse);
    });

    test('曲末：按既有曲末判定从 0 重取', () async {
      final (:service, :player) = await start(mode: PlayMode.sequential);
      player.complete();
      await pumpEventQueue();
      expect(service.position, const Duration(seconds: 30));

      player.calls.clear();
      await service.reloadCurrentStream();
      await pumpEventQueue();

      expect(service.position, Duration.zero);
      expect(
        player.calls.where((call) => call.startsWith('seek:')),
        isEmpty,
        reason: '从 0 重取不需要再 seek 回末位',
      );
      expect(player.calls, isNot(contains('play')), reason: '曲末停住的状态保持');
      expect(service.isPlaying, isFalse);
    });

    test('新源更短：进度按既有口径钳回合法范围', () async {
      final player = _FakeAudioPlayer();
      final service = LocalPlaybackService(
        resolver: (track, {String? quality}) async =>
            PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
        player: player,
      );
      addTearDown(service.dispose);
      await service.playTracks([_track()], 0);
      await pumpEventQueue();
      await service.seek(const Duration(seconds: 20));
      await pumpEventQueue();

      // 重取后播放器解析出更短的源：原进度已越界，复用切音质的钳位口径。
      player.nextSourceDuration = const Duration(seconds: 5);
      player.calls.clear();
      await service.reloadCurrentStream();
      await pumpEventQueue();

      expect(player.duration, const Duration(seconds: 5));
      expect(service.duration, const Duration(seconds: 5));
      expect(service.position, Duration.zero);
      expect(player.calls, isNot(contains('seek:20000')));
    });

    test('取链失败后原地重取：恢复播放而不是停在错误态', () async {
      final player = _FakeAudioPlayer();
      var failNext = true;
      final service = LocalPlaybackService(
        resolver: (track, {String? quality}) async {
          if (failNext) {
            failNext = false;
            throw StateError('取链失败');
          }
          return PlayableStream(Uri.parse('file:///tmp/molia-test.mp3'));
        },
        player: player,
      );
      addTearDown(service.dispose);
      await service.playTracks([_track()], 0);
      await pumpEventQueue();
      expect(service.isPlaying, isFalse);
      expect(service.lastError, isNotNull);

      player.calls.clear();
      await service.reloadCurrentStream();
      await pumpEventQueue();

      expect(service.lastError, isNull);
      expect(player.calls, contains('setAudioSource'));
      expect(player.calls, contains('play'), reason: '失败前用户意图是播放，原地重取要接着出声');
      expect(service.isPlaying, isTrue);
    });
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
    expect(
      player.platformPlays,
      playsBefore + 1,
      reason: 'playing 仍为 true 时直接 play() 不会下发平台请求，必须先前置暂停',
    );
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
    expect(player.calls, [
      'pause',
      'setAudioSource',
      'play',
    ], reason: '自动切歌前先暂停，下一首的 play 必须真正下发到平台');
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
      resolver: (track, {String? quality}) async =>
          PlayableStream(Uri.parse('https://cdn.example/${track.id}.mp3')),
      predownloader: predownloader,
    );
    final player = _FakeAudioPlayer();
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async =>
          PlayableStream(Uri.parse('https://cdn.example/${track.id}.mp3')),
      player: player,
      nextTrackPreloader: preloader,
      audioCacheWriter: PlayingTrackCacheWriter(predownloader: predownloader),
    );
    addTearDown(service.dispose);

    final tracks = [_track(index: 0), _track(index: 1)];
    await service.playTracks(tracks, 0);
    await pumpEventQueue();
    expect(
      preloader.isCacheWriteInFlight(tracks[1]),
      isTrue,
      reason: '起播 A 后应开始预取 B',
    );

    await service.playQueueIndex(1);
    await pumpEventQueue();

    expect(
      predownloader.calls.where((track) => track.id == tracks[1].id),
      hasLength(1),
      reason: 'B 的写入由在途预取负责，不能再起 writer 重下同一首',
    );
    expect(predownloader.cancelled, isNot(contains(tracks[1].id)));
  });

  group('恢复态洗牌排列', () {
    Future<LocalPlaybackService> startShuffle(
      int startIndex, {
      List<int>? shuffleIndices,
    }) async {
      final player = _FakeAudioPlayer();
      final service = LocalPlaybackService(
        resolver: (track, {String? quality}) async =>
            PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
        player: player,
        random: math.Random(11),
      );
      addTearDown(service.dispose);
      await service.setMode(PlayMode.shuffle);
      await service.playTracks(
        [for (var i = 0; i < 3; i++) _track(index: i)],
        startIndex,
        shuffleIndices: shuffleIndices,
      );
      await pumpEventQueue();
      return service;
    }

    test('playTracks 采用传入的本轮排列：next / upNext 与恢复快照同源', () async {
      final service = await startShuffle(0, shuffleIndices: const [0, 2, 1]);

      expect(service.currentIndex, 0);
      expect(service.nextSourceTrack?.title, '测试曲目2');
      expect(service.upNextTracks.map((track) => track.title), [
        '测试曲目2',
        '测试曲目1',
      ]);
      expect(service.queueProjection.upNextIndices, [2, 1]);
    });

    test('非法排列回退为新的一轮：覆盖全队列且当前曲目置首', () async {
      // 重复下标（且缺少当前曲目）不能采用，必须回退为新洗牌。
      final service = await startShuffle(1, shuffleIndices: const [0, 0, 2]);

      final current = service.currentIndex;
      final upNextIndices = service.queueProjection.upNextIndices;
      expect(current, 1);
      expect(upNextIndices, hasLength(2));
      expect({current, ...upNextIndices}, {0, 1, 2});
      expect(upNextIndices.toSet(), hasLength(2), reason: '一轮内不能重复');
      expect(upNextIndices, isNot(contains(current)));
      expect(
        {current, ...upNextIndices},
        {0, 1, 2},
        reason: '新排列把当前曲目置首，剩下两首全在 upNext',
      );
    });
  });

  group('队列编辑', () {
    List<String?> titlesOf(Iterable<SourceTrack> tracks) => [
      for (final track in tracks) track.title,
    ];

    test('移除当前曲目之后的项：队列 / 下标 / 顺序 / revision 同步', () async {
      final started = await start(trackCount: 4);
      final service = started.service;
      final before = service.queueRevision;

      expect(service.removeQueueIndex(2), isTrue);
      expect(titlesOf(service.queueTracks), ['测试曲目0', '测试曲目1', '测试曲目3']);
      expect(service.currentIndex, 0);
      expect(service.queueRevision, before + 1);
      expect(titlesOf(service.upNextTracks), ['测试曲目1', '测试曲目3']);
      // 当前曲目永远不可移除。
      expect(service.removeQueueIndex(0), isFalse);
      expect(service.removeQueueIndex(9), isFalse);
      expect(service.queueTracks, hasLength(3));
    });

    test('移除当前曲目之前的项：currentIndex 前移，已播放顺序重映射', () async {
      final started = await start(mode: PlayMode.sequential, trackCount: 4);
      final service = started.service;
      await service.skipToNext(); // 当前 1，播放顺序记录 0
      await service.skipToNext(); // 当前 2，播放顺序 [0, 1]
      expect(service.currentIndex, 2);

      expect(service.removeQueueIndex(0), isTrue);
      expect(service.currentIndex, 1);
      expect(titlesOf(service.queueTracks), ['测试曲目1', '测试曲目2', '测试曲目3']);
      // 栈里的 0 被移除、1 → 0：上一首仍是曲目 1（不是下标 0 的曲目 2）。
      expect(service.previousSourceTrack?.title, '测试曲目1');
    });

    test('移动跨过当前曲目：当前下标平移，顺序栈按新下标重映射', () async {
      final started = await start(mode: PlayMode.sequential, trackCount: 4);
      final service = started.service;
      await service.skipToNext(); // 当前 1（b），播放顺序 [0]
      await service.skipToNext(); // 当前 2（c），播放顺序 [0, 1]

      // 把队首 a 移到最后：b / c 各前移一格，当前 c 从 2 → 1。
      expect(service.moveQueueIndex(0, 3), isTrue);
      expect(titlesOf(service.queueTracks), [
        '测试曲目1',
        '测试曲目2',
        '测试曲目3',
        '测试曲目0',
      ]);
      expect(service.currentIndex, 1);
      expect(
        service.previousSourceTrack?.title,
        '测试曲目1',
        reason: '离开的 b 下标 1 → 0',
      );
      // 原地 / 越界 / 移动当前曲目都是 no-op。
      expect(service.moveQueueIndex(0, 0), isFalse);
      expect(service.moveQueueIndex(1, 2), isFalse);
      expect(service.moveQueueIndex(0, 9), isFalse);
    });

    test('随机模式：移动是 no-op，移除仍可用且洗牌排列同步', () async {
      final player = _FakeAudioPlayer();
      final service = LocalPlaybackService(
        resolver: (track, {String? quality}) async =>
            PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
        player: player,
        random: math.Random(7),
      );
      addTearDown(service.dispose);
      await service.setMode(PlayMode.shuffle);
      await service.playTracks([
        for (var i = 0; i < 4; i++) _track(index: i),
      ], 1);
      await pumpEventQueue();

      expect(service.moveQueueIndex(0, 2), isFalse);
      expect(service.currentIndex, 1);

      final removed = service.queueTracks[3].title;
      expect(service.removeQueueIndex(3), isTrue);
      expect(service.queueTracks, hasLength(3));
      expect(
        service.queueTracks.map((track) => track.title),
        isNot(contains(removed)),
      );
      expect(
        service.upNextTracks.map((track) => track.title),
        isNot(contains(removed)),
        reason: '洗牌排列不能继续保留已移除下标',
      );
      expect(service.currentIndex, 1);
      expect(service.removeQueueIndex(service.currentIndex), isFalse);
    });

    test('队列编辑后刷新下一首预取：旧目标取消，新目标预载', () async {
      final predownloader = _TaskPredownloader();
      final preloader = NextTrackPreloader(
        resolver: (track, {String? quality}) async =>
            PlayableStream(Uri.parse('https://cdn.example/${track.title}.mp3')),
        predownloader: predownloader,
      );
      final player = _FakeAudioPlayer();
      final service = LocalPlaybackService(
        resolver: (track, {String? quality}) async =>
            PlayableStream(Uri.parse('https://cdn.example/${track.title}.mp3')),
        player: player,
        nextTrackPreloader: preloader,
      );
      addTearDown(service.dispose);

      await service.playTracks([
        _track(index: 0),
        _track(index: 1),
        _track(index: 2),
      ], 0);
      await pumpEventQueue();
      expect(preloader.targetTrackId, _track(index: 1).id);

      // 移除原下一首：新的 next 是曲目 2，旧目标必须取消并重新预载。
      expect(service.removeQueueIndex(1), isTrue);
      await pumpEventQueue();
      expect(predownloader.cancelled, contains(_track(index: 1).id));
      expect(preloader.targetTrackId, _track(index: 2).id);
      expect(
        predownloader.calls.map((track) => track.id),
        contains(_track(index: 2).id),
      );

      // no-op 不触发重新预载。
      final callsBefore = predownloader.calls.length;
      expect(service.removeQueueIndex(9), isFalse);
      await pumpEventQueue();
      expect(predownloader.calls.length, callsBefore);
    });
  });

  group('智能随机', () {
    test('装载随机队列与进入随机各刷新一次证据；读取失败静默降级', () async {
      var calls = 0;
      final player = _FakeAudioPlayer();
      final service = LocalPlaybackService(
        resolver: (track, {String? quality}) async =>
            PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
        player: player,
        random: math.Random(11),
        fadeDuration: Duration.zero,
        recentTrackIds: () async {
          calls++;
          // 第二次故意失败：证据读取不能打断播放或洗牌。
          if (calls == 2) throw StateError('统计库不可用');
          return {'test:a1', 'test:a3'};
        },
      );
      addTearDown(service.dispose);
      await service.setMode(PlayMode.shuffle);

      await service.playTracks([
        for (var i = 0; i < 12; i++) _track(index: i),
      ], 0);
      await pumpEventQueue();
      expect(calls, 1);
      expect(service.isPlaying, isTrue);
      expect(service.queueProjection.upNextIndices, isNotEmpty);

      await service.setMode(PlayMode.listLoop);
      await service.setMode(PlayMode.shuffle);
      expect(calls, 2, reason: '进入随机刷新证据');
      expect(service.isPlaying, isTrue, reason: '证据失败不影响当前播放');
      expect(service.queueProjection.next, isNotNull);
    });

    test('开关从下一轮 / 下一次装载生效，当前轮排列不重排', () async {
      final service = LocalPlaybackService(
        resolver: (track, {String? quality}) async =>
            PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
        player: _FakeAudioPlayer(),
        random: math.Random(21),
        fadeDuration: Duration.zero,
        recentTrackIds: () async => {for (var i = 0; i < 12; i++) 'test:a$i'},
      );
      addTearDown(service.dispose);
      await service.setMode(PlayMode.shuffle);
      await service.playTracks([
        for (var i = 0; i < 12; i++) _track(index: i),
      ], 0);
      await pumpEventQueue();
      expect(service.shuffleRoundWeighted, isTrue);

      final currentRound = service.queueProjection.upNextIndices;
      service.setSmartShuffleEnabled(false);
      expect(service.shuffleRoundWeighted, isTrue, reason: '当前轮不重排');
      expect(service.queueProjection.upNextIndices, currentRound);

      // 走完这一轮（12 首 = 当前 + 11 首，最后一次从末位重洗）：轮末读到
      // 关闭状态 → 下一轮均匀。
      for (var i = 0; i < 12; i++) {
        await service.skipToNext();
      }
      await pumpEventQueue();
      expect(service.shuffleRoundWeighted, isFalse);

      // 重新开启并装载新队列：下一次队列装载即加权。
      service.setSmartShuffleEnabled(true);
      await service.playTracks([
        for (var i = 0; i < 12; i++) _track(index: i),
      ], 0);
      await pumpEventQueue();
      expect(service.shuffleRoundWeighted, isTrue);
    });

    test('关闭智能随机后不读取证据', () async {
      var calls = 0;
      final service = LocalPlaybackService(
        resolver: (track, {String? quality}) async =>
            PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
        player: _FakeAudioPlayer(),
        random: math.Random(2),
        fadeDuration: Duration.zero,
        smartShuffleEnabled: false,
        recentTrackIds: () async {
          calls++;
          return {'test:a1'};
        },
      );
      addTearDown(service.dispose);
      await service.setMode(PlayMode.shuffle);
      await service.setMode(PlayMode.listLoop);
      await service.setMode(PlayMode.shuffle);
      expect(calls, 0, reason: '关闭后完全走均匀随机，不查历史');
    });
  });

  group('桌面输出丢失（端口 → 急停）', () {
    test('会话 unsupported 也订阅 outputLost：急停一次、不淡变', () async {
      final ctx = await startSession(
        sessionSupported: false,
        fadeDuration: const Duration(milliseconds: 300),
      );
      expect(ctx.service.isPlaying, isTrue);
      ctx.player.calls.clear();
      ctx.player.volumeCalls.clear();

      ctx.port.emitOutputLost();
      await pumpEventQueue();

      expect(ctx.player.calls.where((call) => call == 'pause'), hasLength(1));
      expect(ctx.player.volumeCalls, isEmpty, reason: '输出丢失不能走淡出');
      expect(ctx.service.isPlaying, isFalse);

      ctx.port.emitOutputLost();
      await pumpEventQueue();
      expect(
        ctx.player.calls.where((call) => call == 'pause'),
        hasLength(1),
        reason: '重复事件 / 已暂停时保持幂等',
      );
    });

    test('无曲目时输出丢失是无害空操作', () async {
      final player = _FakeAudioPlayer();
      final port = FakePlatformAudioPort(supported: false);
      final settings = ValueNotifier<bool>(true);
      final lifecycle = AudioSessionLifecycle(
        port: port,
        playWithOtherApps: settings,
        platform: TargetPlatform.linux,
      );
      final service = LocalPlaybackService(
        resolver: (track, {String? quality}) async =>
            PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
        player: player,
        audioSession: lifecycle,
        playWithOtherApps: settings,
      );
      addTearDown(service.dispose);
      addTearDown(settings.dispose);
      await pumpEventQueue();
      player.calls.clear();

      port.emitOutputLost();
      await pumpEventQueue();

      expect(player.calls, isEmpty);
      expect(service.isPlaying, isFalse);
    });

    test('dispose 与退出收尾都只释放一次端口', () async {
      final player = _FakeAudioPlayer();
      final port = FakePlatformAudioPort(supported: false);
      final settings = ValueNotifier<bool>(true);
      final lifecycle = AudioSessionLifecycle(
        port: port,
        playWithOtherApps: settings,
        platform: TargetPlatform.linux,
      );
      final service = LocalPlaybackService(
        resolver: (track, {String? quality}) async =>
            PlayableStream(Uri.parse('file:///tmp/molia-test.mp3')),
        player: player,
        audioSession: lifecycle,
        playWithOtherApps: settings,
      );
      await service.playTracks([_track(index: 0)], 0);
      await pumpEventQueue();

      await service.shutdownAudioForQuit();
      service.dispose();
      settings.dispose();
      expect(port.disposeCalls, 1);
    });
  });

  group('淡入淡出', () {
    test('暂停：先淡到静音再暂停，服务仍回报用户音量', () async {
      final (:service, :player) = await start();
      await service.setVolume(0.8);
      service.setFadeDuration(const Duration(milliseconds: 120));
      player.volumeCalls.clear();

      final pause = service.pause();
      expect(service.isPlaying, isTrue, reason: '淡出期间暂停尚未落地');

      await pause;
      expect(service.isPlaying, isFalse);
      expect(player.calls.last, 'pause');
      expect(player.volumeCalls.last, 0.0);
      expect(service.volume, 0.8, reason: '包络不外泄，用户音量不变');
      expect(service.envelopeGain, 0.0);
    });

    test('恢复播放：从静音淡入，结束回到用户音量', () async {
      final (:service, :player) = await start();
      await service.setVolume(0.8);
      service.setFadeDuration(const Duration(milliseconds: 120));
      await service.pause();
      player.volumeCalls.clear();

      await service.toggle();
      await pumpEventQueue();
      // 淡出后播放器已经是 0：起播前不会再重复写一次 0。
      expect(
        player.volumeCalls.isEmpty || player.volumeCalls.first == 0.0,
        isTrue,
        reason: '起播第一声必须是静音',
      );
      expect(service.isPlaying, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 180));
      expect(player.volumeCalls.last, closeTo(0.8, 1e-6));
      expect(service.envelopeGain, 1.0);
    });

    test('切歌不淡变：新源直接使用用户音量', () async {
      final (:service, :player) = await start(trackCount: 2);
      await service.setVolume(0.5);
      service.setFadeDuration(const Duration(milliseconds: 150));
      player.volumeCalls.clear();

      await service.skipToNext();
      await pumpEventQueue();

      expect(player.volumeCalls, isEmpty, reason: '手动切歌保持硬切');
      expect(service.isPlaying, isTrue);
      expect(service.envelopeGain, 1.0);
    });

    test('急停（耳机拔出 / 焦点丢失 / 设备消失）不等淡变', () async {
      final (:service, :player) = await start();
      await service.setVolume(0.6);
      service.setFadeDuration(const Duration(milliseconds: 300));
      player.volumeCalls.clear();
      player.calls.clear();

      final started = DateTime.now();
      await service.pause(urgent: true);
      expect(DateTime.now().difference(started).inMilliseconds, lessThan(120));
      expect(player.volumeCalls, isEmpty);
      expect(player.calls.last, 'pause');
      expect(service.isPlaying, isFalse);
    });

    test('淡变中改音量：立即生效且剩余段从新基值继续', () async {
      final (:service, :player) = await start();
      await service.setVolume(0.8);
      service.setFadeDuration(const Duration(milliseconds: 200));
      await service.pause();
      player.volumeCalls.clear();

      await service.toggle();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await service.setVolume(0.4);
      await Future<void>.delayed(const Duration(milliseconds: 220));

      expect(player.volumeCalls.last, closeTo(0.4, 1e-6));
      expect(service.volume, 0.4);
      expect(service.envelopeGain, 1.0);
      expect(
        player.volumeCalls.any((value) => value > 0.41),
        isFalse,
        reason: '新基值生效后不能继续朝旧音量爬升',
      );
    });

    test('淡变中静音保持无声，取消静音恢复音量', () async {
      final (:service, :player) = await start();
      await service.setVolume(0.6);
      service.setFadeDuration(const Duration(milliseconds: 200));
      await service.pause();
      player.volumeCalls.clear();

      await service.toggle();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await service.setVolume(0);
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(player.volumeCalls.last, 0.0);

      await service.setVolume(0.6);
      expect(player.volumeCalls.last, closeTo(0.6, 1e-6));
    });

    test('暂停淡出中反向播放：最新意图胜出，不真正暂停', () async {
      final (:service, :player) = await start();
      await service.setVolume(0.8);
      service.setFadeDuration(const Duration(milliseconds: 200));
      player.calls.clear();

      final pause = service.pause();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(service.pauseIntentPending, isTrue);

      final play = service.play();
      expect(await pause, isFalse, reason: '被播放意图取代的暂停不落地');
      await play;
      await Future<void>.delayed(const Duration(milliseconds: 240));

      expect(service.isPlaying, isTrue);
      expect(player.calls, isNot(contains('pause')));
      expect(player.volumeCalls.last, closeTo(0.8, 1e-6));
    });

    test('睡眠淡出取代暂停淡出：不遗留暂停意图，后续播放/暂停按键正常', () async {
      final (:service, :player) = await start();
      await service.setVolume(0.8);
      service.setFadeDuration(const Duration(milliseconds: 200));

      final pause = service.pause();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(service.pauseIntentPending, isTrue);

      // 定时关闭开始 / 撤销淡出会取消暂停淡出：此时暂停已作废，意图必须清掉。
      service.startSleepFade(const Duration(milliseconds: 600));
      expect(await pause, isFalse);
      expect(service.pauseIntentPending, isFalse);
      service.cancelSleepFade();
      await Future<void>.delayed(const Duration(milliseconds: 240));
      expect(service.isPlaying, isTrue);

      // 第一次按键仍是「暂停」，不会被误判成反向淡入。
      await service.toggle();
      expect(service.isPlaying, isFalse);
      expect(player.calls.last, 'pause');

      await service.toggle();
      await pumpEventQueue();
      expect(service.isPlaying, isTrue);
    });

    test('淡出完成后紧接暂停不跑第二次淡变', () async {
      final (:service, :player) = await start();
      await service.setVolume(0.7);
      service.setFadeDuration(const Duration(milliseconds: 80));

      service.startSleepFade(const Duration(milliseconds: 80));
      await Future<void>.delayed(const Duration(milliseconds: 130));
      expect(service.envelopeGain, 0.0);

      player.volumeCalls.clear();
      await service.pause();
      expect(player.volumeCalls, isEmpty, reason: '已经静音，暂停立即落地');
      expect(service.isPlaying, isFalse);
    });

    test('睡眠淡出取消：按普通淡变时长回到用户音量', () async {
      final (:service, :player) = await start();
      await service.setVolume(0.6);
      service.setFadeDuration(const Duration(milliseconds: 100));

      service.startSleepFade(const Duration(milliseconds: 80));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      service.cancelSleepFade();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(player.volumeCalls.last, closeTo(0.6, 1e-6));
      expect(service.envelopeGain, 1.0);
      expect(service.isPlaying, isTrue);
    });

    test('淡变不产生快照通知：只在真正暂停时通知一次', () async {
      final (:service, :player) = await start();
      service.setFadeDuration(const Duration(milliseconds: 100));
      var notifications = 0;
      service.changes.addListener(() => notifications++);
      player.volumeCalls.clear();

      await service.pause();
      await pumpEventQueue();
      expect(notifications, 1, reason: '仅播放器状态变化的低频通知');
    });
  });

  test('边播边缓存完成信号：切歌不取消，旧缓存完成后仍上报', () async {
    final cache = _CompletionCacheService();
    final completers = <Completer<bool>>[];
    final cancelled = <int>[];
    final completedTracks = <String>[];
    final recorder = AudioCacheCompletionRecorder(
      onCompleted: (track) => completedTracks.add(track.id),
    );
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async =>
          PlayableStream(Uri.parse('https://cdn.example/${track.id}.mp3')),
      player: _FakeAudioPlayer(),
      cacheService: cache,
      audioCachePlatformSupported: () => true,
      cachingAudioSourceFactory: (uri, path, {headers = const {}}) {
        final index = completers.length;
        final completer = Completer<bool>();
        completers.add(completer);
        return CachingAudioSourceHandle(
          source: AudioSource.uri(uri),
          completed: completer.future,
          cancel: () {
            cancelled.add(index);
            if (!completer.isCompleted) completer.complete(false);
          },
        );
      },
      cacheCompletionRecorder: recorder,
    );
    addTearDown(service.dispose);

    await service.playTracks([_track(index: 0), _track(index: 1)], 0);
    await pumpEventQueue();
    expect(completers, hasLength(1));

    // 切歌发生在完成之前：完成监听由 recorder 持有，不能被取消。
    await service.playTracks([_track(index: 1)], 0);
    await pumpEventQueue();
    expect(cancelled, isEmpty, reason: '切歌不能取消旧缓存完成监听');
    expect(completedTracks, isEmpty);

    // 旧曲目缓存这时才完成：仍要写索引。
    completers[0].complete(true);
    await pumpEventQueue();
    expect(completedTracks, [trackIdOf('test', 0)]);

    // 新曲目完成：再上报一次。
    completers[1].complete(true);
    await pumpEventQueue();
    expect(completedTracks, [trackIdOf('test', 0), trackIdOf('test', 1)]);

    // 失败完成不上报。
    await service.playTracks([_track(index: 2)], 0);
    await pumpEventQueue();
    completers[2].complete(false);
    await pumpEventQueue();
    expect(completedTracks, [trackIdOf('test', 0), trackIdOf('test', 1)]);
  });

  test('快照：低频播放事实同源，高频进度不进快照也不额外通知', () async {
    final (:service, :player) = await start(trackCount: 2);
    var notifications = 0;
    service.changes.addListener(() => notifications++);

    final initial = service.state;
    expect(initial.hasTrack, isTrue);
    expect(initial.queueTracks.length, 2);
    expect(initial.currentIndex, 0);
    expect(initial.currentSourceTrack?.id, service.currentSourceTrack?.id);
    expect(initial.isPlaying, isTrue);
    expect(initial.isLoading, isFalse);
    expect(initial.mode, PlayMode.listLoop);
    expect(initial.duration, const Duration(seconds: 30));
    // 队列版本未变时复用同一份不可变视图：位置 tick 不为快照复制整条队列。
    expect(
      identical(service.state.queueTracks, service.state.queueTracks),
      isTrue,
    );

    // 低频状态变化：快照同源更新，且只通知一次。
    await service.setMode(PlayMode.shuffle);
    expect(service.state.mode, PlayMode.shuffle);
    expect(notifications, 1);

    await service.enqueueTracks([_track(index: 2)]);
    expect(service.state.queueTracks.length, 3);
    expect(notifications, 2);

    // 位置 tick 只走原有独立通道（400ms 节流），不因为快照化提高频率。
    player.emitPosition(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(service.position, const Duration(seconds: 5));
    expect(service.state.duration, initial.duration);
    expect(notifications, 2, reason: '位置推进不立刻发快照');
  });

  group('音频缓存单写者约束（#60）', () {
    Future<Directory> tempCacheDir() async {
      final dir = await Directory.systemTemp.createTemp('molia_audio_cache');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      return dir;
    }

    ({_FakeAudioPlayer player, LocalPlaybackService service}) buildService(
      Directory dir, {
      required CachingAudioSourceHandle Function(Uri uri, String cachePath)
      createSource,
      bool cacheEnabled = true,
    }) {
      final player = _FakeAudioPlayer();
      final service = LocalPlaybackService(
        resolver: (track, {String? quality}) async =>
            PlayableStream(Uri.parse('https://cdn.example/${track.id}.mp3')),
        player: player,
        cacheService: _CompletionCacheService(
          audioDir: dir.path,
          enabled: cacheEnabled,
        ),
        audioCachePlatformSupported: () => true,
        cachingAudioSourceFactory: (uri, path, {headers = const {}}) =>
            createSource(uri, path),
      );
      addTearDown(service.dispose);
      return (player: player, service: service);
    }

    test('同一缓存文件已有 writer：重播不再建第二个 writer', () async {
      final dir = await tempCacheDir();
      final completers = <Completer<bool>>[];
      final paths = <String>[];
      final (:player, :service) = buildService(
        dir,
        createSource: (uri, cachePath) {
          final completer = Completer<bool>();
          completers.add(completer);
          paths.add(cachePath);
          return CachingAudioSourceHandle(
            source: AudioSource.uri(uri),
            completed: completer.future,
            cancel: () {},
          );
        },
      );

      await service.playTracks([_track(index: 0)], 0);
      await pumpEventQueue();
      expect(completers, hasLength(1));

      // 换队列 / 重播同一首：旧 writer 还在写同一个 `.part`。
      await service.playTracks([_track(index: 0)], 0);
      await pumpEventQueue();
      expect(completers, hasLength(1), reason: '同一路径只能有一个 writer');
      final source = player.lastAudioSource;
      expect(source, isA<UriAudioSource>());
      expect((source! as UriAudioSource).uri.scheme, 'https');

      // 在途 writer 结束：所有权释放，下次起播可以重新写。
      completers[0].complete(false);
      await pumpEventQueue();
      await service.playTracks([_track(index: 0)], 0);
      await pumpEventQueue();
      expect(completers, hasLength(2));
      expect(paths.toSet(), hasLength(1), reason: '同一曲目始终同一缓存文件');
    });

    test('完整缓存已在位：直接 file://，不建 writer，并清掉残留 .part', () async {
      final dir = await tempCacheDir();
      final track = _track(index: 0);
      final complete = File(
        p.join(dir.path, AudioCacheStore.keyForSource(track)),
      )..writeAsBytesSync(const [1, 2, 3]);
      final partial = File('${complete.path}.part')
        ..writeAsBytesSync(const [4, 5]);
      var factoryCalls = 0;
      final (:player, :service) = buildService(
        dir,
        createSource: (uri, cachePath) {
          factoryCalls++;
          return CachingAudioSourceHandle(
            source: AudioSource.uri(uri),
            completed: Future<bool>.value(false),
            cancel: () {},
          );
        },
      );

      await service.playTracks([track], 0);
      await pumpEventQueue();

      expect(factoryCalls, 0, reason: '完整缓存已在位不应再建 writer');
      expect(partial.existsSync(), isFalse, reason: '残留半成品会挡住 file:// 命中');
      expect(complete.existsSync(), isTrue);
      final source = player.lastAudioSource;
      expect(source, isA<UriAudioSource>());
      expect((source! as UriAudioSource).uri.toFilePath(), complete.path);
    });

    test('音频缓存开关关闭：仍命中完整文件，只是不再写新缓存', () async {
      final dir = await tempCacheDir();
      final track = _track(index: 0);
      final complete = File(
        p.join(dir.path, AudioCacheStore.keyForSource(track)),
      )..writeAsBytesSync(const [1, 2, 3]);
      var factoryCalls = 0;
      final (:player, :service) = buildService(
        dir,
        cacheEnabled: false,
        createSource: (uri, cachePath) {
          factoryCalls++;
          return CachingAudioSourceHandle(
            source: AudioSource.uri(uri),
            completed: Completer<bool>().future,
            cancel: () {},
          );
        },
      );

      await service.playTracks([track], 0);
      await pumpEventQueue();

      expect(factoryCalls, 0);
      final source = player.lastAudioSource;
      expect((source! as UriAudioSource).uri.toFilePath(), complete.path);
    });

    test('只有 .part 半成品（上次中断）：仍建 writer 接管', () async {
      final dir = await tempCacheDir();
      final track = _track(index: 0);
      final cachePath = p.join(dir.path, AudioCacheStore.keyForSource(track));
      File('$cachePath.part').writeAsBytesSync(const [4, 5]);
      var factoryCalls = 0;
      final (:player, :service) = buildService(
        dir,
        createSource: (uri, cachePath) {
          factoryCalls++;
          return CachingAudioSourceHandle(
            source: AudioSource.uri(uri),
            completed: Completer<bool>().future,
            cancel: () {},
          );
        },
      );

      await service.playTracks([track], 0);
      await pumpEventQueue();

      expect(factoryCalls, 1);
      final source = player.lastAudioSource;
      expect((source! as UriAudioSource).uri.scheme, 'https');
    });

    test('登记表：写入者完成 / 失败后释放同一路径', () async {
      final registry = AudioCacheWriterRegistry();
      final first = Completer<bool>();
      final firstHandle = CachingAudioSourceHandle(
        source: AudioSource.uri(Uri.parse('https://cdn.example/a.mp3')),
        completed: first.future,
        cancel: () {},
      );
      final secondHandle = CachingAudioSourceHandle(
        source: AudioSource.uri(Uri.parse('https://cdn.example/a.mp3')),
        completed: Completer<bool>().future,
        cancel: () {},
      );

      expect(registry.acquire('/tmp/a', firstHandle), isTrue);
      expect(registry.acquire('/tmp/a', secondHandle), isFalse);
      expect(registry.isWriting('/tmp/a'), isTrue);
      expect(registry.count, 1);

      first.complete(false);
      await pumpEventQueue();
      expect(registry.isWriting('/tmp/a'), isFalse);
      expect(registry.acquire('/tmp/a', secondHandle), isTrue);
    });
  });
}

/// 只覆盖缓存源装配用到的三个方法：单测不碰真实目录 / prefs。
class _CompletionCacheService extends CacheService {
  _CompletionCacheService({
    this.audioDir = '/tmp/molia-test-audio-cache',
    this.enabled = true,
  });

  final String audioDir;

  /// 「音频缓存」开关（关闭时只读已有完整文件，不再写新缓存）。
  final bool enabled;

  @override
  Future<bool> audioEnabled() async => enabled;

  @override
  Future<String?> audioCacheDirPath() async => audioDir;

  @override
  Future<int> enforceAudioLimit({bool force = false}) async => 0;
}

String trackIdOf(String sourceKey, int index) => '$sourceKey:a$index';
