/// 原生定时关闭唤醒的工厂（Android / iOS 走 MethodChannel，其余平台
/// no-op）。
library;

import 'sleep_timer_alarm_io.dart' as impl;
import 'sleep_timer_alarm_types.dart';

export 'sleep_timer_alarm_types.dart';

/// 创建当前平台的原生定时器（Android / iOS 有实现，其余平台 no-op）。
SleepTimerAlarm createSleepTimerAlarm() => impl.createSleepTimerAlarm();
