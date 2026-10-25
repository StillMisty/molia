import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/playback/audio_focus_policy.dart';

void main() {
  group('shouldPauseForAudioFocus', () {
    test('开启同时播放：Android 忽略焦点丢失', () {
      expect(
        shouldPauseForAudioFocus(
          playWithOtherApps: true,
          platform: TargetPlatform.android,
        ),
        isFalse,
      );
    });

    test('开启同时播放：iOS / macOS 仍暂停系统级中断', () {
      for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
        expect(
          shouldPauseForAudioFocus(
            playWithOtherApps: true,
            platform: platform,
          ),
          isTrue,
          reason: '$platform 的 mixWithOthers 已挡掉其他应用音频，收到中断即来电 / Siri',
        );
      }
    });

    test('关闭同时播放：所有平台都按中断暂停', () {
      for (final platform in TargetPlatform.values) {
        expect(
          shouldPauseForAudioFocus(
            playWithOtherApps: false,
            platform: platform,
          ),
          isTrue,
          reason: '$platform',
        );
      }
    });
  });

  group('audioSessionConfigurationFor', () {
    test('保留 duck 的暂停语义', () {
      final config = audioSessionConfigurationFor(
        playWithOtherApps: false,
        platform: TargetPlatform.android,
      );
      expect(config.androidWillPauseWhenDucked, isTrue);
      expect(config.avAudioSessionCategoryOptions, isNull);
    });

    test('开启同时播放时 iOS / macOS 增加 mixWithOthers', () {
      for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
        final config = audioSessionConfigurationFor(
          playWithOtherApps: true,
          platform: platform,
        );
        expect(
          config.avAudioSessionCategoryOptions
              ?.contains(AVAudioSessionCategoryOptions.mixWithOthers),
          isTrue,
          reason: '$platform',
        );
      }
    });

    test('Android 不写 Apple 会话选项', () {
      final config = audioSessionConfigurationFor(
        playWithOtherApps: true,
        platform: TargetPlatform.android,
      );
      expect(config.avAudioSessionCategoryOptions, isNull);
      expect(config.androidAudioAttributes?.usage, AndroidAudioUsage.media);
    });
  });
}
