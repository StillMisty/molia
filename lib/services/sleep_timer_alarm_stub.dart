import 'sleep_timer_alarm_types.dart';

/// Web：没有可用的原生定时器，保持纯 Dart timer。
SleepTimerAlarm createSleepTimerAlarm() => const NoopSleepTimerAlarm();
