/// 前台激活权限的平台适配器（Windows，ADR-0038）。
///
/// Windows 的前台锁会阻止后台进程调用 `SetForegroundWindow`：第二实例由
/// 用户点击启动、拥有前台权限，因此在通知主实例 `show` 之前先调用
/// `AllowSetForegroundWindow(primaryPid)`。非 Windows / 调用失败都返回 false。
library;

import 'dart:io' show Platform;

import 'package:win32/win32.dart' as win32;

/// 允许 [pid] 进程设置前台窗口。
bool allowSetForegroundWindow(int pid) {
  if (!Platform.isWindows || pid <= 0) return false;
  try {
    return win32.AllowSetForegroundWindow(pid).value;
  } catch (_) {
    return false;
  }
}
