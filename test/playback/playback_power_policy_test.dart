/// 移动端播放功耗策略：前后台 / 桌面歌词切换、位置采样档位与会话落盘节流。
///
/// 与 `AppPresence` 无关（后者是桌面窗口可见性）；这里只验证策略本身与
/// `LocalPlaybackService` 的采样选择，不触碰 just_audio 平台通道。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/ports/music_source.dart' show PlayableStream;
import 'package:molia/playback/local_playback_service.dart';
import 'package:molia/playback/playback_power_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlaybackPowerPolicy', () {
    test('默认前台：高频采样、1s 会话落盘', () {
      final policy = PlaybackPowerPolicy();
      addTearDown(policy.dispose);

      expect(policy.isForeground, isTrue);
      expect(policy.desktopLyricsActive, isFalse);
      expect(policy.keepHighFrequencyPosition, isTrue);
      expect(policy.sessionSaveInterval, const Duration(seconds: 1));
    });

    test('退后台：降为 1s 采样判据关闭、会话落盘放宽到 15s', () {
      final policy = PlaybackPowerPolicy();
      addTearDown(policy.dispose);

      policy.markBackground();
      expect(policy.isForeground, isFalse);
      expect(policy.keepHighFrequencyPosition, isFalse);
      expect(policy.sessionSaveInterval, const Duration(seconds: 15));

      policy.markForeground();
      expect(policy.isForeground, isTrue);
      expect(policy.keepHighFrequencyPosition, isTrue);
      expect(policy.sessionSaveInterval, const Duration(seconds: 1));
    });

    test('后台开桌面歌词：仍按高频采样，会话落盘保持后台 15s', () {
      final policy = PlaybackPowerPolicy();
      addTearDown(policy.dispose);

      policy.markBackground();
      policy.setDesktopLyricsActive(true);

      expect(policy.desktopLyricsActive, isTrue);
      expect(policy.keepHighFrequencyPosition, isTrue);
      expect(
        policy.sessionSaveInterval,
        const Duration(seconds: 15),
        reason: '桌面歌词只影响位置采样，不改变会话落盘节流',
      );

      policy.setDesktopLyricsActive(false);
      expect(policy.keepHighFrequencyPosition, isFalse);
    });

    test('重复置位不通知（幂等）', () {
      final policy = PlaybackPowerPolicy();
      addTearDown(policy.dispose);
      var notifications = 0;
      policy.addListener(() => notifications++);

      policy.markForeground();
      expect(notifications, 0);

      policy.markBackground();
      expect(notifications, 1);
      policy.markBackground();
      expect(notifications, 1);

      policy.setDesktopLyricsActive(false);
      expect(notifications, 1);
      policy.setDesktopLyricsActive(true);
      expect(notifications, 2);
      policy.setDesktopLyricsActive(true);
      expect(notifications, 2);

      policy.markForeground();
      expect(notifications, 3);
    });
  });

  group('后台位置采样决策', () {
    test('前台或桌面歌词开启：跟随高频位置流', () {
      expect(
        positionSamplingModeFor(keepHighFrequency: true, playing: true),
        PositionSamplingMode.highFrequency,
      );
      expect(
        positionSamplingModeFor(keepHighFrequency: true, playing: false),
        PositionSamplingMode.highFrequency,
        reason: '前台暂停也要更新进度（拖动 / 恢复后立即显示）',
      );
    });

    test('后台播放：1s 轮询', () {
      expect(
        positionSamplingModeFor(keepHighFrequency: false, playing: true),
        PositionSamplingMode.periodic,
      );
    });

    test('后台暂停：不采样（不建 Timer）', () {
      expect(
        positionSamplingModeFor(keepHighFrequency: false, playing: false),
        PositionSamplingMode.none,
      );
    });

    test('LocalPlaybackService 跟随策略切换档位', () async {
      final policy = PlaybackPowerPolicy();
      addTearDown(policy.dispose);
      final service = LocalPlaybackService(
        resolver: (track, {String? quality}) async =>
            PlayableStream(Uri.parse('http://127.0.0.1/a.wav')),
        powerPolicy: policy,
      );
      addTearDown(service.dispose);

      expect(service.positionSamplingMode, PositionSamplingMode.highFrequency);
      expect(service.positionStreamActive, isTrue);
      expect(service.positionSampleTimerActive, isFalse);

      // 测试环境没有真实播放（playing=false）：后台即「不采样」。
      policy.markBackground();
      expect(service.positionSamplingMode, PositionSamplingMode.none);
      expect(service.positionStreamActive, isFalse);
      expect(service.positionSampleTimerActive, isFalse);

      // 后台开桌面歌词：回到高频。
      policy.setDesktopLyricsActive(true);
      expect(service.positionSamplingMode, PositionSamplingMode.highFrequency);
      expect(service.positionStreamActive, isTrue);
      expect(service.positionSampleTimerActive, isFalse);

      policy.markForeground();
      expect(service.positionSamplingMode, PositionSamplingMode.highFrequency);
      expect(service.positionStreamActive, isTrue);
      expect(service.positionSampleTimerActive, isFalse);
    });
  });
}
