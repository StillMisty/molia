/// 数据链路耗时埋点（opt-in）。
///
/// 与 `frame_stats.dart` 共用 `--dart-define=MOLIA_PERF_TRACE=true`：关闭时
/// 只留一次编译期常量判断，不创建 Stopwatch、不注册 Timer、不打日志，
/// 正常包在热点路径上零额外开销。为什么单独一层：帧统计只覆盖 UI 流水线，
/// 资料库 / 统计 / 本地数据这些同步或异步查询的耗时需要按 op 单独聚合。
///
/// 输出统一为一行 JSON（`op` / `ms` / 可选整数字段），消费方按 `molia.perf`
/// 过滤即可，不依赖 Flutter UI。
library;

import 'dart:convert';

import 'package:logging/logging.dart';

/// 数据路径耗时记录器（全静态，不持有状态）。
abstract final class DataPathTrace {
  /// 编译期开关：只有 `MOLIA_PERF_TRACE=true` 的构建才有采样开销。
  static const bool enabled = bool.fromEnvironment('MOLIA_PERF_TRACE');

  static final Logger _logger = Logger('molia.perf');

  /// 记录一次同步操作；[fields] 只在启用时求值（通常用于操作后的计数）。
  static T sync<T>(
    String op,
    T Function() body, {
    Map<String, Object?> Function()? fields,
  }) {
    if (!enabled) return body();
    final watch = Stopwatch()..start();
    try {
      return body();
    } finally {
      watch.stop();
      _log(op, watch.elapsedMicroseconds, fields);
    }
  }

  /// 记录一次异步操作；异常照常抛出，耗时仍会记录。
  ///
  /// 关闭时直接返回业务 Future，不额外经过一层 async 函数（热点路径上
  /// 少一次 Future 包装）。
  static Future<T> async<T>(
    String op,
    Future<T> Function() body, {
    Map<String, Object?> Function()? fields,
  }) {
    if (!enabled) return body();
    return _timedAsync(op, body, fields);
  }

  /// 记录一段已测量的耗时（调用方自己持有 Stopwatch）。
  ///
  /// 用于「计时起点早于本函数、且中间夹着结果判定」的场景，例如搜索防抖
  /// （输入到真正发请求）与歌词缓存命中（先读文件才能知道 hit/miss）。
  static void record(
    String op,
    Duration elapsed, {
    Map<String, Object?> Function()? fields,
  }) {
    if (!enabled) return;
    _log(op, elapsed.inMicroseconds, fields);
  }

  /// 记录一个没有时长语义的事件（场景标记 / 阶段边界）。
  static void event(String op, {Map<String, Object?> Function()? fields}) {
    if (!enabled) return;
    _log(op, 0, fields);
  }

  static Future<T> _timedAsync<T>(
    String op,
    Future<T> Function() body,
    Map<String, Object?> Function()? fields,
  ) async {
    final watch = Stopwatch()..start();
    try {
      return await body();
    } finally {
      watch.stop();
      _log(op, watch.elapsedMicroseconds, fields);
    }
  }

  static void _log(
    String op,
    int elapsedMicroseconds,
    Map<String, Object?> Function()? fields,
  ) {
    // 毫秒保留两位小数：与帧统计口径一致，也避免长浮点噪声。
    final ms = (elapsedMicroseconds / 1000 * 100).round() / 100;
    final payload = <String, Object?>{
      'op': op,
      'ms': ms,
      // 墙上时刻用于把多个 op 串成一条端到端链路；分桶统计不依赖它。
      'ts': DateTime.now().millisecondsSinceEpoch,
      if (fields != null) ...fields(),
    };
    _logger.info(jsonEncode(payload));
  }
}
