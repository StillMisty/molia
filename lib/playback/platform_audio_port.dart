/// 平台音频边界：会话配置 / 激活 / 释放与平台事件流（ADR-0035）。
///
/// 为什么单独成模块：播放层只认识这一个窄接口，测试用记录型假实现即可覆盖
/// 激活顺序、配置快照与释放时机；真实的 `audio_session` 调用只出现在移动端
/// 适配器里，桌面在本次工作流里是 no-op（P1 的桌面输出监听复用同一接口）。
library;

import 'package:audio_session/audio_session.dart';

/// 平台音频端口：唯一允许触碰平台音频会话的地方。
///
/// 事件流在 [start] 之后有效（移动端实现要等 `AudioSession.instance` 解析
/// 完成）；桌面 no-op 的流始终为空。
abstract class PlatformAudioPort {
  /// 是否有真实平台实现。桌面 no-op 为 false：生命周期仍然可调用，但不做
  /// 配置 / 激活 / 释放，桌面播放行为与改动前完全一致。
  bool get supported;

  Stream<AudioInterruptionEvent> get interruptions;
  Stream<void> get outputLost;
  Stream<AudioDevicesChangedEvent> get deviceChanges;

  /// 建立平台连接（移动端解析 `AudioSession` 单例）。幂等、失败只记日志。
  Future<void> start();

  Future<void> configure(AudioSessionConfiguration configuration);

  /// 请求音频会话 / 焦点；返回是否拿到（iOS `setActive`、Android 焦点请求）。
  Future<bool> activate();

  /// 释放会话 / 放弃焦点；[notifyOthers] 在 iOS 上通知其他应用可以恢复。
  Future<void> deactivate({required bool notifyOthers});

  Future<void> dispose();
}

/// 桌面 / 测试用 no-op 端口：不配置、不激活、不产生事件。
class NoopPlatformAudioPort implements PlatformAudioPort {
  const NoopPlatformAudioPort();

  @override
  bool get supported => false;

  @override
  Stream<AudioInterruptionEvent> get interruptions => const Stream.empty();

  @override
  Stream<void> get outputLost => const Stream.empty();

  @override
  Stream<AudioDevicesChangedEvent> get deviceChanges => const Stream.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {}

  @override
  Future<bool> activate() async => true;

  @override
  Future<void> deactivate({required bool notifyOthers}) async {}

  @override
  Future<void> dispose() async {}
}
