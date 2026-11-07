/// 单实例协议的纯逻辑：metadata 编解码、校验与探测结论（无 IO，便于单测）。
///
/// **锁与 metadata 分开**：`single_instance.lock` 只由 OS 文件锁占用
/// （`RandomAccessFile.lock`），不承载内容；pid / port 写在 sidecar
/// [metadataFileName] 里。这样 Windows 上锁住的范围不会被另一进程读取，
/// 也避免「先创建文件、后写内容」的并发启动竞态。
///
/// IO（文件锁 / loopback 连接 / 监听）收在 `single_instance_io.dart`。
library;

import 'dart:convert';

/// 本进程在单实例协议里的角色。
enum SingleInstanceRole {
  /// 本进程持有锁：继续启动（监听后来实例的显示请求）。
  primary,

  /// 已有实例在运行且已请它显示窗口：调用方应立即退出。
  secondary,
}

/// 旧版（Roaming 锁）升级守卫的结论。
enum LegacyUpgradeAction {
  /// 没有旧版实例 / 旧 pid 已退出：继续抢新锁。
  proceed,

  /// 旧版实例存活且能连上：按 secondary 退出。
  secondary,

  /// 旧版实例存活但连不上：仍按 secondary 退出（绝不能进入 primary 后
  /// 复制一个正在被旧版本写入的数据库）。
  secondaryUnresponsive,
}

/// 单实例 metadata 协议：`{"pid": <int>, "port": <int>}`。
///
/// `port = 0` 表示主实例仍在运行但 loopback 监听不可用（监听失败 / 端口
/// 尚未绑定）；后来实例看到存活 pid 即按 secondary 退出，不把「连不上」
/// 误判成陈旧锁。
class SingleInstanceLock {
  SingleInstanceLock._();

  /// 锁文件旁边存放 pid / port 的 sidecar 文件名。
  static const String metadataFileName = 'single_instance.json';

  /// 最多尝试重新抢锁的次数（锁冲突但 metadata 未就绪 / 旧 pid 已退出）。
  static const int maxAcquireAttempts = 3;

  static String encode({required int pid, required int port}) =>
      jsonEncode(<String, int>{'pid': pid, 'port': port});

  /// 解析 metadata；格式不符（半写、被截断）返回 null。
  static ({int pid, int port})? parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final pid = decoded['pid'];
      final port = decoded['port'];
      if (pid is! int || port is! int) return null;
      if (pid <= 0 || port < 0 || port > 65535) return null;
      return (pid: pid, port: port);
    } catch (_) {
      return null;
    }
  }

  /// 文件锁失败是否代表「另一个进程正持有锁」。
  ///
  /// `RandomAccessFile.lock` 在 POSIX 上返回 EAGAIN / EACCES，在 Windows 上
  /// 返回 `ERROR_SHARING_VIOLATION` / `ERROR_LOCK_VIOLATION`。其它错误
  /// （如文件系统不支持锁）不能当成 primary 已存在，否则应用会静默不启动。
  static bool isLockConflict(int? errorCode, {required bool onWindows}) {
    if (errorCode == null) return false;
    if (onWindows) return errorCode == 32 || errorCode == 33;
    return errorCode == 11 || errorCode == 13 || errorCode == 35;
  }

  /// 旧版 Roaming 锁的升级守卫结论（新锁抢到之前检查一次）。
  ///
  /// 旧文件不存在 / 读不出 / pid 已退出都继续；pid 存活时无论是否能连上
  /// 都按 secondary 退出——连不上说明旧版本可能卡住，仍不能冒险进入
  /// primary 复制它正在写入的数据库。
  static LegacyUpgradeAction decideUpgradeGuard({
    required bool lockExists,
    required bool readable,
    required bool alive,
    required bool connected,
  }) {
    if (!lockExists || !readable || !alive) {
      return LegacyUpgradeAction.proceed;
    }
    return connected
        ? LegacyUpgradeAction.secondary
        : LegacyUpgradeAction.secondaryUnresponsive;
  }
}
