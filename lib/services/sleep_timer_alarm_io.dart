import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import 'sleep_timer_alarm_types.dart';

/// IO 平台工厂：Android / iOS 使用原生定时器；桌面保持纯 Dart timer。
SleepTimerAlarm createSleepTimerAlarm() {
  if (Platform.isAndroid || Platform.isIOS) {
    return MethodChannelSleepTimerAlarm();
  }
  return const NoopSleepTimerAlarm();
}

/// 经平台通道调度原生定时器（Android Handler / iOS DispatchQueue）。
///
/// 原生实现只负责「到点唤醒 Dart」；暂停动作仍由控制器统一执行，避免原生
/// 与 Dart 各有一套播放状态。通道缺失（测试 / 旧版本）时静默降级为纯 Dart。
class MethodChannelSleepTimerAlarm implements SleepTimerAlarm {
  MethodChannelSleepTimerAlarm({
    MethodChannel? channel,
    bool? supported,
  })  : _channel = channel ?? const MethodChannel(kSleepTimerAlarmChannel),
        _supported = supported ?? (Platform.isAndroid || Platform.isIOS) {
    _channel.setMethodCallHandler(_handleCall);
  }

  final MethodChannel _channel;

  /// 平台探测可注入（测试在桌面宿主上验证通道契约）。
  final bool _supported;

  static final Logger _logger = Logger('molia.sleep_timer_alarm');

  @override
  SleepTimerFired? onFired;

  Future<void> _handleCall(MethodCall call) async {
    if (call.method != 'fired') return;
    final token = switch (call.arguments) {
      final int value => value,
      final Map<Object?, Object?> map => (map['token'] as num?)?.toInt(),
      _ => null,
    };
    if (token != null) onFired?.call(token);
  }

  @override
  void arm(Duration delay, int token) {
    if (!_supported || delay <= Duration.zero) return;
    unawaited(_invoke('arm', {
      'millis': delay.inMilliseconds,
      'token': token,
    }));
  }

  @override
  void cancel() {
    if (!_supported) return;
    unawaited(_invoke('cancel', const <String, Object?>{}));
  }

  Future<void> _invoke(String method, Map<String, Object?> arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } catch (e) {
      // 通道缺失 / 原生失败：退回纯 Dart timer，不阻断播放与 UI。
      _logger.fine(() => '原生定时关闭 $method 失败（忽略）: $e');
    }
  }

  @override
  void dispose() {
    onFired = null;
    _channel.setMethodCallHandler(null);
    cancel();
  }
}
