/// `audio_session` 的移动端端口实现（Android / iOS）。
///
/// 只做「平台调用 + 事件流转发」，不含生命周期决策（归
/// `AudioSessionLifecycle`）；失败一律降级为日志 / false，不允许把插件异常
/// 抛进播放链路。
library;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import 'platform_audio_port.dart';

class MobileAudioSessionPort implements PlatformAudioPort {
  AudioSession? _session;
  Future<AudioSession>? _opening;

  @override
  bool get supported => true;

  @override
  Stream<AudioInterruptionEvent> get interruptions =>
      _session?.interruptionEventStream ?? const Stream.empty();

  @override
  Stream<void> get outputLost =>
      _session?.becomingNoisyEventStream ?? const Stream.empty();

  @override
  Stream<AudioDevicesChangedEvent> get deviceChanges =>
      _session?.devicesChangedEventStream ?? const Stream.empty();

  Future<AudioSession> _open() {
    final existing = _session;
    if (existing != null) return Future.value(existing);
    return _opening ??= AudioSession.instance.then(
      (session) {
        _session = session;
        _opening = null;
        return session;
      },
      onError: (Object e) {
        _opening = null;
        debugPrint('[PlatformAudioPort] 打开音频会话失败: $e');
        throw e;
      },
    );
  }

  @override
  Future<void> start() async {
    try {
      await _open();
    } catch (_) {
      // 没有插件实现 / 平台通道不可用时保持静默：播放仍可用，只是没有
      // 焦点与设备事件。
    }
  }

  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {
    try {
      final session = await _open();
      await session.configure(configuration);
    } catch (e) {
      debugPrint('[PlatformAudioPort] 配置音频会话失败: $e');
    }
  }

  @override
  Future<bool> activate() async {
    // 显式 false = 平台拒绝焦点（通话 / 独占应用）；异常 = 端口不可用。
    // 两者必须区分：前者交给生命周期等待重试，后者降级为无会话播放。
    final session = await _open();
    return session.setActive(true);
  }

  @override
  Future<void> deactivate({required bool notifyOthers}) async {
    try {
      final session = await _open();
      await session.setActive(
        false,
        // iOS 上让其他应用知道可以恢复；Android 忽略该参数。每次释放都带上，
        // 避免「Molia 暂停后别的播放器仍停在暂停态」。
        avAudioSessionSetActiveOptions: notifyOthers
            ? AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation
            : null,
      );
    } catch (e) {
      debugPrint('[PlatformAudioPort] 释放音频会话失败: $e');
    }
  }

  @override
  Future<void> dispose() async {
    _session = null;
    _opening = null;
  }
}
