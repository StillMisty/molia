/// 单实例锁文件的纯逻辑：内容编解码、内容校验与探测结论（无 IO，便于单测）。
///
/// IO（锁文件创建 / loopback 连接 / 监听）收在 `single_instance_io.dart`。
library;

import 'dart:convert';

/// 本进程在单实例协议里的角色。
enum SingleInstanceRole {
  /// 本进程持有锁：继续启动（监听后来实例的显示请求）。
  primary,

  /// 已有实例在运行且已请它显示窗口：调用方应立即退出。
  secondary,
}

/// 抢锁失败且既有实例探测完成后的下一步。
enum SingleInstanceAction {
  /// 既有实例活着（已发出显示请求）。
  secondary,

  /// 陈旧锁（崩溃残留 / 半写内容 / pid 已退出）：清掉重抢。
  retryAcquire,

  /// 重试耗尽：保守按主实例继续（宁可多开一个窗口，也不卡死启动）。
  fallbackPrimary,
}

/// 锁文件协议：`{"pid": <int>, "port": <int>}`。
class SingleInstanceLock {
  SingleInstanceLock._();

  /// 最大抢占次数：每次失败后删除陈旧锁并等待重试。
  static const int maxAcquireAttempts = 3;

  static String encode({required int pid, required int port}) =>
      jsonEncode(<String, int>{'pid': pid, 'port': port});

  /// 解析锁文件内容；格式不符（半写、被截断、旧版本）返回 null。
  static ({int pid, int port})? parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final pid = decoded['pid'];
      final port = decoded['port'];
      if (pid is! int || port is! int) return null;
      if (pid <= 0 || port <= 0 || port > 65535) return null;
      return (pid: pid, port: port);
    } catch (_) {
      return null;
    }
  }

  /// 既有实例探测结论 → 下一步动作。
  ///
  /// [alive] 是 OS 对锁文件里 pid 的存活判定：pid 已退出时不必再等 loopback
  /// 连接超时（强杀 / 更新后很常见），直接清锁重抢；pid 存活但连不上才按
  /// 尝试次数保守处理。
  static SingleInstanceAction decide({
    required bool connected,
    required bool alive,
    required int attempt,
  }) {
    if (connected) return SingleInstanceAction.secondary;
    if (!alive) return SingleInstanceAction.retryAcquire;
    return attempt < maxAcquireAttempts
        ? SingleInstanceAction.retryAcquire
        : SingleInstanceAction.fallbackPrimary;
  }
}
