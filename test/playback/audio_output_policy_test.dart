// 构造测试设备要引用 audio_session 里标记为 experimental 的设备类型枚举。
// ignore_for_file: experimental_member_use

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/playback/audio_output_policy.dart';

AudioDevice _device(
  String id,
  AudioDeviceType type, {
  bool isInput = false,
  bool isOutput = true,
}) =>
    AudioDevice(
      id: id,
      name: id,
      isInput: isInput,
      isOutput: isOutput,
      type: type,
    );

void main() {
  group('shouldPauseForDeviceRemoval', () {
    test('外接输出设备被移除 → 暂停', () {
      for (final type in [
        AudioDeviceType.bluetoothA2dp,
        AudioDeviceType.bluetoothSco,
        AudioDeviceType.wiredHeadphones,
        AudioDeviceType.wiredHeadset,
        AudioDeviceType.usbAudio,
        AudioDeviceType.hdmi,
        AudioDeviceType.dock,
        AudioDeviceType.carAudio,
        AudioDeviceType.airPlay,
      ]) {
        expect(
          shouldPauseForDeviceRemoval({_device(type.name, type)}),
          isTrue,
          reason: '$type',
        );
      }
    });

    test('内置扬声器 / 听筒被移除 → 不暂停（路由切到耳机）', () {
      for (final type in [
        AudioDeviceType.builtInSpeaker,
        AudioDeviceType.builtInEarpiece,
      ]) {
        expect(
          shouldPauseForDeviceRemoval({_device(type.name, type)}),
          isFalse,
          reason: '$type',
        );
      }
    });

    test('输入设备被移除 → 不暂停', () {
      expect(
        shouldPauseForDeviceRemoval({
          _device(
            'mic',
            AudioDeviceType.builtInMic,
            isInput: true,
            isOutput: false,
          ),
        }),
        isFalse,
      );
      expect(
        shouldPauseForDeviceRemoval({
          _device(
            'bt-mic',
            AudioDeviceType.bluetoothA2dp,
            isInput: true,
            isOutput: false,
          ),
        }),
        isFalse,
        reason: '即使是非内置类型，只作输入也与播放无关',
      );
    });

    test('只新增设备（devicesRemoved 为空）→ 不暂停', () {
      expect(shouldPauseForDeviceRemoval(const {}), isFalse);
    });

    test('混合移除里包含外接输出 → 暂停', () {
      expect(
        shouldPauseForDeviceRemoval({
          _device('speaker', AudioDeviceType.builtInSpeaker),
          _device('bt', AudioDeviceType.bluetoothA2dp),
        }),
        isTrue,
      );
    });

    test('未知类型的输出被移除 → 暂停（宁可多停一次）', () {
      expect(
        shouldPauseForDeviceRemoval({
          _device('unknown', AudioDeviceType.unknown),
        }),
        isTrue,
      );
    });
  });
}
