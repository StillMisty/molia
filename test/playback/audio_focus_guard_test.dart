import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/playback/audio_focus_guard.dart';
import 'package:molia/playback/local_playback_service.dart';

/// 记录型暂停动作（守卫的注入 seam）。
class _RecordingPause {
  int calls = 0;

  /// 本次暂停是否真的发生了（无曲目 / 本来已暂停 → false）。
  bool result = true;

  Future<bool> call() async {
    calls++;
    return result;
  }
}

class _RecordingResume {
  int calls = 0;

  Future<void> call() async {
    calls++;
  }
}

/// 只记录暂停调用的服务替身：不触碰播放器平台通道，验证真实接线
/// （中断流 → 守卫 → `LocalPlaybackService.pause`）。
class _RecordingService extends LocalPlaybackService {
  _RecordingService({
    required Stream<AudioInterruptionEvent> interruptions,
    super.playWithOtherApps,
    Stream<void>? becomingNoisy,
  }) : super(
          resolver: (track, {String? quality}) async =>
              'http://127.0.0.1/a.wav',
          // 注入假流：走 `_configureAudioSession` 的守卫装配，不初始化插件会话。
          audioInterruptions: interruptions,
          audioBecomingNoisy: becomingNoisy,
        );

  int pauseCalls = 0;

  @override
  Future<bool> pause({bool fromInterruption = false}) async {
    pauseCalls++;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioFocusGuard', () {
    late bool shouldPause;
    late _RecordingPause pause;
    late _RecordingResume resume;
    late StreamController<AudioInterruptionEvent> events;
    late AudioFocusGuard guard;

    setUp(() {
      shouldPause = true;
      pause = _RecordingPause();
      resume = _RecordingResume();
      events = StreamController<AudioInterruptionEvent>();
      guard = AudioFocusGuard(
        shouldPause: () => shouldPause,
        onFocusLoss: pause.call,
        onFocusGain: resume.call,
      );
      guard.attach(events.stream);
    });

    tearDown(() async {
      await guard.detach();
      await events.close();
    });

    test('丢失焦点（begin）→ 暂停一次；系统可续播的 end → 续播一次', () async {
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(pause.calls, 1);

      events.add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(resume.calls, 1);
    });

    test('策略关闭暂停时：begin / end 都不动作', () async {
      shouldPause = false;
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(pause.calls, 0);

      events.add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(resume.calls, 0);
    });

    test('duck 类型的 begin 按暂停处理，duck end 不续播', () async {
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.duck));
      await pumpEventQueue();
      expect(pause.calls, 1);

      events.add(AudioInterruptionEvent(false, AudioInterruptionType.duck));
      await pumpEventQueue();
      expect(resume.calls, 0);
    });

    test('不可续播的结束事件（unknown）不续播', () async {
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(pause.calls, 1);

      events.add(AudioInterruptionEvent(false, AudioInterruptionType.unknown));
      await pumpEventQueue();
      expect(resume.calls, 0);
    });

    test('暂停动作返回 false（本来没在播）→ 结束时不续播', () async {
      pause.result = false;
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(pause.calls, 1);

      events.add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(resume.calls, 0);
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
      expect(resume.calls, 0);
    });

    test('手动取消待续播后，焦点归还不抢播', () async {
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(pause.calls, 1);

      guard.cancelPendingResume();
      events.add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(resume.calls, 0);
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

    test('策略运行期切换：下一次事件按新值处理', () async {
      shouldPause = false;
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(pause.calls, 0);

      shouldPause = true;
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(pause.calls, 1);
    });
  });

  group('LocalPlaybackService 接线', () {
    test('开启同时播放（默认）→ 焦点丢失不暂停', () async {
      final events = StreamController<AudioInterruptionEvent>();
      addTearDown(events.close);
      final service = _RecordingService(interruptions: events.stream);
      await pumpEventQueue();

      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(service.pauseCalls, 0);
    });

    test('关闭同时播放 → 焦点丢失暂停；设置切换即时生效', () async {
      final events = StreamController<AudioInterruptionEvent>();
      addTearDown(events.close);
      final settings = ValueNotifier<bool>(false);
      addTearDown(settings.dispose);
      final service = _RecordingService(
        interruptions: events.stream,
        playWithOtherApps: settings,
      );
      await pumpEventQueue();

      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(service.pauseCalls, 1);

      settings.value = true;
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(service.pauseCalls, 1, reason: '开启后不再因为焦点丢失暂停');
    });

    test('耳机拔出事件 → 暂停（just_audio 内建处理已关闭）', () async {
      final events = StreamController<AudioInterruptionEvent>();
      final noisy = StreamController<void>();
      addTearDown(events.close);
      addTearDown(noisy.close);
      final service = _RecordingService(
        interruptions: events.stream,
        becomingNoisy: noisy.stream,
      );
      await pumpEventQueue();

      noisy.add(null);
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
