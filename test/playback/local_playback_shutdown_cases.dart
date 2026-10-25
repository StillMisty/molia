/// 退出前的音频收尾：先暂停再释放播放器，且与 `dispose()` 幂等共存。
///
/// 退出路径不经过 provider dispose，所以这里用假播放器钉住调用顺序与
/// 「只释放一次」——真实设备上的爆音是否消失仍需 Windows 真机验证。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:molia/domain/ports/music_source.dart' show PlayableStream;
import 'package:molia/playback/local_playback_service.dart';

/// 最小播放器替身：只覆写服务构造与退出收尾用到的成员，不触碰平台通道。
class _FakeAudioPlayer extends AudioPlayer {
  _FakeAudioPlayer()
      : super(
          // 不订阅 audio_session 的中断 / becomingNoisy 流：测试里没有插件。
          handleInterruptions: false,
        );

  final List<String> calls = [];
  final _playerState = StreamController<PlayerState>.broadcast(sync: true);
  final _position = StreamController<Duration>.broadcast(sync: true);

  @override
  bool get playing => false;

  @override
  ProcessingState get processingState => ProcessingState.idle;

  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => null;

  @override
  Stream<PlayerState> get playerStateStream => _playerState.stream;

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Future<void> pause() async {
    calls.add('pause');
  }

  @override
  Future<void> setVolume(double volume) async {
    calls.add('setVolume');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _playerState.close();
    await _position.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAudioPlayer player;
  late LocalPlaybackService service;

  setUp(() {
    // Linux 没有 audio_session 实现，服务构造时直接跳过会话配置。
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    player = _FakeAudioPlayer();
    service = LocalPlaybackService(
      resolver: (track, {String? quality}) async =>
          PlayableStream(Uri.parse('http://127.0.0.1/a.wav')),
      player: player,
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('退出收尾先 pause 再 dispose（先让设备停止出数据）', () async {
    await service.shutdownAudioForQuit();

    expect(player.calls, ['pause', 'dispose']);
    service.dispose();
  });

  test('重复调用幂等：第二次不产生新的调用', () async {
    await service.shutdownAudioForQuit();
    await service.shutdownAudioForQuit();

    expect(player.calls, ['pause', 'dispose']);
    service.dispose();
  });

  test('先退出收尾再 dispose：播放器不会被释放第二次', () async {
    await service.shutdownAudioForQuit();
    service.dispose();

    expect(player.calls, ['pause', 'dispose']);
  });
}
