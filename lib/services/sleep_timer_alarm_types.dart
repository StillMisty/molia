/// 定时关闭的「原生唤醒」端口。
///
/// Dart `Timer` 在熄屏 / Doze / 后台挂起时可能被节流或整段冻结；倒计时的
/// 绝对 deadline 逻辑再正确，没有一次回调也无法到点暂停。Android / iOS 原生
/// 侧各挂一个定时器，到点经平台通道把 token 回传给 Dart，控制器再执行既有的
/// `_fire()`。平台不提供实现（桌面 / 测试）时 [NoopSleepTimerAlarm]
/// 保持纯 Dart timer 行为。
library;

/// 平台通道名（Android `SleepTimerChannelHandler` / iOS
/// `SleepTimerChannelHandler.swift` 对齐）。
const String kSleepTimerAlarmChannel = 'top.stillmisty.molia/sleep_timer';

/// 原生定时器到点回调；[token] 用于丢弃已被覆盖 / 取消的旧回调。
typedef SleepTimerFired = void Function(int token);

/// 原生定时器端口。
abstract interface class SleepTimerAlarm {
  /// 到点回调（控制器构造后回填）。
  set onFired(SleepTimerFired? callback);

  /// 在 [delay] 后唤醒；重复调用覆盖旧定时。
  void arm(Duration delay, int token);

  /// 取消当前定时（幂等）。
  void cancel();

  /// 释放通道 / 取消定时。
  void dispose();
}

/// 空实现：桌面 / 单测（没有原生实现时仍由 Dart timer 驱动）。
class NoopSleepTimerAlarm implements SleepTimerAlarm {
  const NoopSleepTimerAlarm();

  @override
  set onFired(SleepTimerFired? callback) {}

  @override
  void arm(Duration delay, int token) {}

  @override
  void cancel() {}

  @override
  void dispose() {}
}
