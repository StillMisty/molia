// 构造测试设备要引用 audio_session 里标记为 experimental 的设备类型枚举。
// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/ports/music_source.dart' show PlayableStream;
import 'package:molia/playback/audio_focus_guard.dart';
import 'package:molia/playback/audio_focus_policy.dart';
import 'package:molia/playback/audio_session_lifecycle.dart';
import 'package:molia/playback/local_playback_service.dart';

import '../support/fake_platform_audio_port.dart';

/// 记录型动作（守卫的注入 seam）。
class _RecordingBoolAction {
  int calls = 0;
  bool result = true;

  Future<bool> call() async {
    calls++;
    return result;
  }
}

class _RecordingAction {
  int calls = 0;

  Future<void> call() async {
    calls++;
  }
}

/// 只记录暂停调用的服务替身：不触碰播放器平台通道，验证真实接线
/// （端口事件流 → 守卫 → `LocalPlaybackService.pause`）。
class _RecordingService extends LocalPlaybackService {
  _RecordingService({
    required AudioSessionLifecycle audioSession,
    super.playWithOtherApps,
  }) : super(
         resolver: (track, {String? quality}) async =>
             PlayableStream(Uri.parse('http://127.0.0.1/a.wav')),
         audioSession: audioSession,
       );

  int pauseCalls = 0;

  @override
  Future<bool> pause({
    bool fromInterruption = false,
    bool urgent = false,
  }) async {
    pauseCalls++;
    return true;
  }
}

AudioDevice _device(String id, AudioDeviceType type) =>
    AudioDevice(id: id, name: id, isInput: false, isOutput: true, type: type);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioFocusGuard', () {
    late bool playWithOtherApps;
    late TargetPlatform platform;
    late _RecordingBoolAction pause;
    late _RecordingBoolAction duck;
    late _RecordingAction resume;
    late _RecordingAction restore;
    late _RecordingAction settled;
    late StreamController<AudioInterruptionEvent> events;
    late AudioFocusGuard guard;

    setUp(() {
      playWithOtherApps = true;
      platform = TargetPlatform.android;
      pause = _RecordingBoolAction();
      duck = _RecordingBoolAction();
      resume = _RecordingAction();
      restore = _RecordingAction();
      settled = _RecordingAction();
      events = StreamController<AudioInterruptionEvent>();
      guard = AudioFocusGuard(
        actionFor:
            (event, {required pausedForFocus, required duckedForFocus}) =>
                audioFocusActionFor(
                  event: event,
                  playWithOtherApps: playWithOtherApps,
                  platform: platform,
                  pausedForFocus: pausedForFocus,
                  duckedForFocus: duckedForFocus,
                ),
        onPause: pause.call,
        onResume: resume.call,
        onDuck: duck.call,
        onRestore: restore.call,
        onSettled: settled.call,
      );
      guard.attach(events.stream);
    });

    tearDown(() async {
      await guard.detach();
      await events.close();
    });

    Future<void> addAndPump(AudioInterruptionEvent event) async {
      events.add(event);
      await pumpEventQueue();
    }

    test('关闭混播：丢失焦点 → 暂停；可续播的 end → 续播', () async {
      playWithOtherApps = false;
      await addAndPump(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      expect(pause.calls, 1);

      await addAndPump(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      expect(resume.calls, 1);
      expect(settled.calls, 1);
    });

    test('开启混播：duck begin 压低、duck end 恢复一次', () async {
      await addAndPump(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      expect(duck.calls, 1);
      expect(pause.calls, 0);

      await addAndPump(
        AudioInterruptionEvent(false, AudioInterruptionType.duck),
      );
      expect(restore.calls, 1);
      expect(resume.calls, 0);
    });

    test('永久失焦（unknown）在混播开启时忽略', () async {
      await addAndPump(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown),
      );
      expect(pause.calls, 0);
      expect(duck.calls, 0);

      await addAndPump(
        AudioInterruptionEvent(false, AudioInterruptionType.unknown),
      );
      expect(resume.calls, 0);
      expect(restore.calls, 0);
    });

    test('未压低过的 duck end 不恢复；未暂停过的 pause end 不续播', () async {
      await addAndPump(
        AudioInterruptionEvent(false, AudioInterruptionType.duck),
      );
      expect(restore.calls, 0);

      await addAndPump(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      expect(resume.calls, 0);
    });

    test('可续播的结束事件是 unknown 时不续播，但清掉暂停记账', () async {
      playWithOtherApps = false;
      await addAndPump(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await addAndPump(
        AudioInterruptionEvent(false, AudioInterruptionType.unknown),
      );
      expect(resume.calls, 0);

      // 记账已清：再来的 pause end 不会补播。
      await addAndPump(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      expect(resume.calls, 0);
    });

    test('暂停动作返回 false（本来没在播）→ 结束时不续播', () async {
      playWithOtherApps = false;
      pause.result = false;
      await addAndPump(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await addAndPump(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      expect(resume.calls, 0);
    });

    test('压低动作返回 false（暂停 / 停止中）→ 结束时也不恢复', () async {
      duck.result = false;
      await addAndPump(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      expect(duck.calls, 1);
      await addAndPump(
        AudioInterruptionEvent(false, AudioInterruptionType.duck),
      );
      expect(restore.calls, 0);
    });

    test('用户手动操作取消待续播与待恢复', () async {
      await addAndPump(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      guard.cancelPendingInterruption();
      await addAndPump(
        AudioInterruptionEvent(false, AudioInterruptionType.duck),
      );
      expect(restore.calls, 0);

      playWithOtherApps = false;
      await addAndPump(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      guard.cancelPendingInterruption();
      await addAndPump(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      expect(resume.calls, 0);
    });

    test('end 事件在前、begin 在后：不动作', () async {
      await addAndPump(
        AudioInterruptionEvent(false, AudioInterruptionType.unknown),
      );
      expect(pause.calls, 0);
      expect(resume.calls, 0);
    });

    test('重新 attach 替换旧流：旧流事件不再触发', () async {
      final replacement = StreamController<AudioInterruptionEvent>();
      addTearDown(replacement.close);
      guard.attach(replacement.stream);

      await addAndPump(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      expect(pause.calls, 0);

      replacement.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await pumpEventQueue();
      expect(pause.calls, 1);
    });

    test('detach 后已排队的暂停不再执行', () async {
      playWithOtherApps = false;
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await guard.detach();
      await pumpEventQueue();
      expect(pause.calls, 0);
    });

    test('策略运行期切换：下一次事件按新值处理', () async {
      playWithOtherApps = false;
      await addAndPump(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      expect(pause.calls, 1);

      playWithOtherApps = true;
      await addAndPump(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      expect(pause.calls, 2, reason: 'planner 每次事件读取最新设置');
      await addAndPump(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      expect(duck.calls, 1);
    });

    test('duck 中收到永久失焦：恢复音量，避免 duck-end 丢失后一直发闷', () async {
      await addAndPump(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      expect(duck.calls, 1);

      await addAndPump(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown),
      );
      expect(restore.calls, 1);
    });
  });

  group('LocalPlaybackService 接线', () {
    late FakePlatformAudioPort port;
    late ValueNotifier<bool> settings;

    setUp(() {
      port = FakePlatformAudioPort();
      settings = ValueNotifier<bool>(true);
    });

    tearDown(() async {
      settings.dispose();
      await port.dispose();
    });

    AudioSessionLifecycle lifecycle() => AudioSessionLifecycle(
      port: port,
      playWithOtherApps: settings,
      platform: TargetPlatform.android,
    );

    test('开启同时播放 → 其他播放器出声暂停、duck 不暂停', () async {
      final service = _RecordingService(
        audioSession: lifecycle(),
        playWithOtherApps: settings,
      );
      await pumpEventQueue();

      port.emitInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown),
      );
      await pumpEventQueue();
      expect(service.pauseCalls, 0);

      port.emitInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await pumpEventQueue();
      expect(service.pauseCalls, 1, reason: '混播只忽略永久失焦，不忽略暂停型中断');

      port.emitInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      await pumpEventQueue();
      expect(service.pauseCalls, 1, reason: 'duck 走压低，不暂停');
    });

    test('关闭同时播放 → 任何焦点丢失都暂停；设置切换即时生效', () async {
      settings.value = false;
      final service = _RecordingService(
        audioSession: lifecycle(),
        playWithOtherApps: settings,
      );
      await pumpEventQueue();

      port.emitInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await pumpEventQueue();
      expect(service.pauseCalls, 1);

      settings.value = true;
      port.emitInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await pumpEventQueue();
      expect(service.pauseCalls, 2, reason: '混播开启后 pause 型中断仍应暂停');
      port.emitInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown),
      );
      await pumpEventQueue();
      expect(service.pauseCalls, 2, reason: '开启后永久失焦忽略');
    });

    test('耳机拔出事件 → 暂停（just_audio 内建处理已关闭）', () async {
      final service = _RecordingService(
        audioSession: lifecycle(),
        playWithOtherApps: settings,
      );
      await pumpEventQueue();

      port.emitOutputLost();
      await pumpEventQueue();
      expect(service.pauseCalls, 1);
    });

    test('蓝牙输出断开 → 暂停（设备回调不依赖音频焦点）', () async {
      final service = _RecordingService(
        audioSession: lifecycle(),
        playWithOtherApps: settings,
      );
      await pumpEventQueue();

      port.emitDeviceChanges(
        AudioDevicesChangedEvent(
          devicesRemoved: {_device('bt', AudioDeviceType.bluetoothA2dp)},
        ),
      );
      await pumpEventQueue();
      expect(service.pauseCalls, 1);
    });

    test('内置扬声器被移除（路由切到耳机）→ 不暂停', () async {
      final service = _RecordingService(
        audioSession: lifecycle(),
        playWithOtherApps: settings,
      );
      await pumpEventQueue();

      port.emitDeviceChanges(
        AudioDevicesChangedEvent(
          devicesRemoved: {_device('speaker', AudioDeviceType.builtInSpeaker)},
        ),
      );
      await pumpEventQueue();
      expect(service.pauseCalls, 0);
    });

    test('未注入生命周期时构造不抛（桌面 no-op 端口）', () async {
      final service = LocalPlaybackService(
        resolver: (track, {String? quality}) async =>
            PlayableStream(Uri.parse('http://127.0.0.1/a.wav')),
      );
      await pumpEventQueue();
      expect(service.hasTrack, isFalse);
      expect(service.isPlaying, isFalse);
      service.dispose();
    });
  });
}
