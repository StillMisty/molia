/// 原生定时关闭唤醒的工厂（条件导入：IO 平台走 MethodChannel，Web 用 no-op）。
library;

import 'sleep_timer_alarm_stub.dart'
    if (dart.library.io) 'sleep_timer_alarm_io.dart' as impl;
import 'sleep_timer_alarm_types.dart';

export 'sleep_timer_alarm_types.dart';

/// 创建当前平台的原生定时器（Android / iOS 有实现，其余平台 no-op）。
SleepTimerAlarm createSleepTimerAlarm() => impl.createSleepTimerAlarm();
