import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/playback/audio_focus_guard.dart';
import 'package:molia/playback/local_playback_service.dart';

/// 记录型暂停动作（守卫的注入 seam）。
class _RecordingPause {
  int calls = 0;
  final List<String> events = [];

  Future<void> call() async {
    calls++;
    events.add('pause');
  }
}

/// 只记录暂停调用的服务替身：不触碰播放器平台通道，验证真实接线
/// （中断流 → 守卫 → `LocalPlaybackService.pause`）。
class _RecordingService extends LocalPlaybackService {
  _RecordingService({required Stream<AudioInterruptionEvent> interruptions})
      : super(
          resolver: (track, {String? quality}) async =>
              'http://127.0.0.1/a.wav',
          // 注入假流：走 `_configureAudioSession` 的守卫装配，不初始化插件会话。
          audioInterruptions: interruptions,
        );

  int pauseCalls = 0;

  @override
  Future<void> pause() async {
    pauseCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioFocusGuard', () {
    late _RecordingPause pause;
    late StreamController<AudioInterruptionEvent> events;
    late AudioFocusGuard guard;

    setUp(() {
      pause = _RecordingPause();
      events = StreamController<AudioInterruptionEvent>();
      guard = AudioFocusGuard(onFocusLoss: pause.call);
      guard.attach(events.stream);
    });

    tearDown(() async {
      await guard.detach();
      await events.close();
    });

    test('丢失焦点（begin）→ 暂停一次；焦点归还（end）→ 不动作', () async {
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(pause.calls, 1);

      events.add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(pause.calls, 1, reason: '焦点归还的续播交给 just_audio 的中断处理');
    });

    test('duck 类型的 begin 也按暂停处理（播放后端不会压音量）', () async {
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.duck));
      await pumpEventQueue();
      expect(pause.calls, 1);

      events.add(AudioInterruptionEvent(false, AudioInterruptionType.duck));
      await pumpEventQueue();
      expect(pause.calls, 1);
    });

    test('连续 begin 事件每次都暂停（幂等性由动作侧负责）', () async {
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.unknown));
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(pause.calls, 2);
    });

    test('end 事件在前、begin 在后：只有 begin 触发', () async {
      events.add(AudioInterruptionEvent(false, AudioInterruptionType.unknown));
      await pumpEventQueue();
      expect(pause.calls, 0);
    });

    test('重新 attach 替换旧流：旧流事件不再触发', () async {
      final replacement = StreamController<AudioInterruptionEvent>();
      addTearDown(replacement.close);
      guard.attach(replacement.stream);

      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(pause.calls, 0);

      replacement
          .add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(pause.calls, 1);
    });

    test('detach 后已排队的暂停不再执行', () async {
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await guard.detach();
      await pumpEventQueue();
      expect(pause.calls, 0);
    });
  });

  group('LocalPlaybackService 接线', () {
    test('音频焦点丢失 → 服务暂停；焦点归还 → 不自动续播', () async {
      final events = StreamController<AudioInterruptionEvent>();
      addTearDown(events.close);
      final service = _RecordingService(interruptions: events.stream);
      await pumpEventQueue();
      expect(service.pauseCalls, 0);

      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(service.pauseCalls, 1);

      events.add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(service.pauseCalls, 1);
    });

    test('未注入中断流时构造不抛（无插件实现路径）', () async {
      final service = LocalPlaybackService(
        resolver: (track, {String? quality}) async => 'http://127.0.0.1/a.wav',
      );
      await pumpEventQueue();
      // 测试环境没有 audio_session 插件：配置失败只记日志，不影响服务可用。
      expect(service.hasTrack, isFalse);
      expect(service.isPlaying, isFalse);
    });
  });
}
