// audio_session 把设备类型标成 experimental；区分内置 / 外接输出只有它提供，
// 这里只读 type，不依赖其值域稳定（未知类型按外接处理）。
// ignore_for_file: experimental_member_use

/// 音频输出设备变化的纯决策：哪些设备被移除时必须暂停播放。
///
/// 与「与其他应用同时播放」无关：设置只决定是否被其他应用的声音打断，
/// 物理输出断开（拔耳机 / 蓝牙断链 / USB DAC 掉线）任何情况下都要停，
/// 否则声音会突然从外放出来。
///
/// 与事件装配（`LocalPlaybackService`）分开，便于单测覆盖设备类型差异。
library;

import 'package:audio_session/audio_session.dart';

/// 被移除的设备中是否有「非内置」输出设备。
///
/// 输入设备（麦克风）与播放无关，忽略；内置扬声器 / 听筒被移除通常意味着
/// 路由刚切到耳机，继续播放才是预期。未知类型按外接设备处理（宁可多停一次，
/// 不能让声音意外外放）。
bool shouldPauseForDeviceRemoval(Set<AudioDevice> devicesRemoved) {
  return devicesRemoved.any(
    (device) => device.isOutput && !_builtInOutputTypes.contains(device.type),
  );
}

const _builtInOutputTypes = {
  AudioDeviceType.builtInSpeaker,
  AudioDeviceType.builtInEarpiece,
};
