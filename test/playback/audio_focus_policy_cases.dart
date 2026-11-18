import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/playback/audio_focus_policy.dart';

AudioInterruptionEvent _event(bool begin, AudioInterruptionType type) =>
    AudioInterruptionEvent(begin, type);

AudioFocusAction _action({
  required bool begin,
  required AudioInterruptionType type,
  required bool playWithOtherApps,
  required TargetPlatform platform,
  bool pausedForFocus = false,
  bool duckedForFocus = false,
}) => audioFocusActionFor(
  event: _event(begin, type),
  playWithOtherApps: playWithOtherApps,
  platform: platform,
  pausedForFocus: pausedForFocus,
  duckedForFocus: duckedForFocus,
);

void main() {
  group('audioFocusActionFor：Android 开启混播', () {
    test('其他播放器出声（pause）→ 暂停', () {
      expect(
        _action(
          begin: true,
          type: AudioInterruptionType.pause,
          playWithOtherApps: true,
          platform: TargetPlatform.android,
        ),
        AudioFocusAction.pause,
      );
    });

    test('语音提示（duck）→ 压低', () {
      expect(
        _action(
          begin: true,
          type: AudioInterruptionType.duck,
          playWithOtherApps: true,
          platform: TargetPlatform.android,
        ),
        AudioFocusAction.duck,
      );
    });

    test('永久失焦（unknown）→ 忽略，继续播放', () {
      expect(
        _action(
          begin: true,
          type: AudioInterruptionType.unknown,
          playWithOtherApps: true,
          platform: TargetPlatform.android,
        ),
        AudioFocusAction.none,
      );
    });

    test('duck 结束且本应用压过 → 恢复音量', () {
      expect(
        _action(
          begin: false,
          type: AudioInterruptionType.duck,
          playWithOtherApps: true,
          platform: TargetPlatform.android,
          duckedForFocus: true,
        ),
        AudioFocusAction.restore,
      );
    });

    test('暂停结束且本应用暂停过 → 续播', () {
      expect(
        _action(
          begin: false,
          type: AudioInterruptionType.pause,
          playWithOtherApps: true,
          platform: TargetPlatform.android,
          pausedForFocus: true,
        ),
        AudioFocusAction.resume,
      );
    });
  });

  group('audioFocusActionFor：关闭混播 / Apple', () {
    test('关闭混播时 Android 任何 begin 都暂停（含 duck / unknown）', () {
      for (final type in AudioInterruptionType.values) {
        expect(
          _action(
            begin: true,
            type: type,
            playWithOtherApps: false,
            platform: TargetPlatform.android,
          ),
          AudioFocusAction.pause,
          reason: '$type',
        );
      }
    });

    test('iOS / macOS 开启混播仍把任何 begin 当系统级中断暂停', () {
      for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
        for (final type in AudioInterruptionType.values) {
          expect(
            _action(
              begin: true,
              type: type,
              playWithOtherApps: true,
              platform: platform,
            ),
            AudioFocusAction.pause,
            reason: '$platform / $type',
          );
        }
      }
    });

    test('桌面其它平台保持独占语义', () {
      for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
        expect(
          _action(
            begin: true,
            type: AudioInterruptionType.duck,
            playWithOtherApps: true,
            platform: platform,
          ),
          AudioFocusAction.pause,
          reason: '$platform',
        );
      }
    });
  });

  group('audioFocusActionFor：结束事件', () {
    test('本应用没暂停 / 没压低时不抢播、不恢复', () {
      for (final type in AudioInterruptionType.values) {
        for (final platform in TargetPlatform.values) {
          expect(
            _action(
              begin: false,
              type: type,
              playWithOtherApps: true,
              platform: platform,
            ),
            AudioFocusAction.none,
            reason: '$platform / $type',
          );
        }
      }
    });

    test('只恢复自己的动作：暂停过才续播，压过才恢复', () {
      expect(
        _action(
          begin: false,
          type: AudioInterruptionType.pause,
          playWithOtherApps: false,
          platform: TargetPlatform.android,
          duckedForFocus: true,
        ),
        AudioFocusAction.none,
        reason: 'duck 记账不能触发续播',
      );
      expect(
        _action(
          begin: false,
          type: AudioInterruptionType.duck,
          playWithOtherApps: false,
          platform: TargetPlatform.android,
          pausedForFocus: true,
        ),
        AudioFocusAction.none,
        reason: '暂停记账不能触发恢复音量',
      );
    });
  });

  group('audioSessionConfigurationFor', () {
    test('Android 开启混播：transient may-duck 且不因 duck 暂停', () {
      final config = audioSessionConfigurationFor(
        playWithOtherApps: true,
        platform: TargetPlatform.android,
      );
      expect(
        config.androidAudioFocusGainType,
        AndroidAudioFocusGainType.gainTransientMayDuck,
      );
      expect(config.androidWillPauseWhenDucked, isFalse);
      expect(config.avAudioSessionCategoryOptions, isNull);
    });

    test('Android 关闭混播：普通 gain 且 duck 按暂停处理', () {
      final config = audioSessionConfigurationFor(
        playWithOtherApps: false,
        platform: TargetPlatform.android,
      );
      expect(config.androidAudioFocusGainType, AndroidAudioFocusGainType.gain);
      expect(config.androidWillPauseWhenDucked, isTrue);
    });

    test('开启同时播放时只有 Apple 平台增加 mixWithOthers', () {
      for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
        final config = audioSessionConfigurationFor(
          playWithOtherApps: true,
          platform: platform,
        );
        expect(
          config.avAudioSessionCategoryOptions?.contains(
            AVAudioSessionCategoryOptions.mixWithOthers,
          ),
          isTrue,
          reason: '$platform',
        );
      }
      expect(
        audioSessionConfigurationFor(
          playWithOtherApps: true,
          platform: TargetPlatform.android,
        ).avAudioSessionCategoryOptions,
        isNull,
      );
    });
  });
}
