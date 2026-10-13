import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

/// 应用日志装配（`package:logging` 全局只在这里配置一次）。
///
/// 为什么必须显式装配：`package:logging` 默认既不设 level 也不挂 handler，
/// 未装配时所有日志直接被丢弃。装配点有两个，都调本函数：
/// `lib/main.dart`（运行时）与 `test/flutter_test_config.dart`（`flutter test` 全程）。
///
/// 为什么开分层日志：本仓库的 `molia.*` logger 要保留 `fine` 级排障日志，
/// 而依赖包在 `fine` 级打印播放器生命周期等高频内容
/// （如 `just_audio_media_kit` 的 `JustAudioMediaKit` / `MediaKitPlayer`）。
/// 分层按 logger 树继承 level，两边的可见性可以分开控制。
/// `hierarchicalLoggingEnabled` 是全局开关，必须在第一次 `log()` 之前设置。
void initAppLogging({Level level = Level.FINE}) {
  if (_initialized) return;
  _initialized = true;

  hierarchicalLoggingEnabled = true;
  Logger('molia').level = level;
  // 依赖包停在 INFO：其 WARNING/SEVERE 仍会透出（如 media_kit 播放错误）
  Logger.root.level = Level.INFO;
  // SEVERE 自动补调用点堆栈；更低级别不带堆栈，保证单行输出的可读性
  recordStackTraceAtLevel = Level.SEVERE;

  Logger.root.onRecord.listen(_writeRecord);
}

bool _initialized = false;

/// 单行输出：`时间 级别 logger 名: 消息`，错误与堆栈各占后续行。
void _writeRecord(LogRecord record) {
  final buffer = StringBuffer()
    ..write(_formatTime(record.time))
    ..write(' ')
    ..write(record.level.name.padRight(7))
    ..write(' ')
    ..write(record.loggerName)
    ..write(': ')
    ..write(record.message);
  if (record.error != null) {
    buffer.write('\n    error: ${record.error}');
  }
  if (record.stackTrace != null) {
    buffer.write('\n${record.stackTrace}');
  }
  debugPrint(buffer.toString());
}

String _formatTime(DateTime time) {
  String two(int value) => value < 10 ? '0$value' : '$value';
  String three(int value) =>
      value < 10 ? '00$value' : (value < 100 ? '0$value' : '$value');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
      '.${three(time.millisecond)}';
}
