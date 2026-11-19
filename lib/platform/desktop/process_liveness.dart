/// 进程存活探测的平台适配器（ADR-0038）。
///
/// 原生符号只在这里出现：Windows 复用 `package:win32` 的上游生成绑定，POSIX
/// 走 `tool/ffigen_system.dart` 生成的 shim。业务语义（失败保守返回存活）由
/// 本文件保证，调用方 `services/window/process_liveness.dart` 只做转发。
library;

import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:win32/win32.dart' as win32;

import 'system_ffi.g.dart' as system;

/// 目标 pid 是否仍存活。
///
/// 查询失败 / 权限不足时保守返回 true：宁可多等一次连接，也不要误删活实例
/// 的锁、多开一个窗口。
bool isProcessAlive(int pid) {
  if (pid <= 0) return false;
  if (Platform.isWindows) return _isProcessAliveWindows(pid);
  if (Platform.isLinux || Platform.isMacOS) return _isProcessAlivePosix(pid);
  return true;
}

bool _isProcessAliveWindows(int pid) {
  try {
    // SYNCHRONIZE：只需要等进程退出，不需要读它的内存。
    final opened = win32.OpenProcess(win32.PROCESS_SYNCHRONIZE, false, pid);
    final handle = opened.value;
    if (handle.address == 0) {
      // ERROR_ACCESS_DENIED（5）：进程存在但无权打开，按存活处理；
      // ERROR_INVALID_PARAMETER（87）等其它错误才视为已退出。
      return opened.error == win32.ERROR_ACCESS_DENIED;
    }
    try {
      final result = win32.WaitForSingleObject(handle, 0).value;
      // WAIT_TIMEOUT：未退出；WAIT_OBJECT_0：已退出；
      // WAIT_FAILED：查询失败，保守按存活处理。
      return result == win32.WAIT_TIMEOUT || result == win32.WAIT_FAILED;
    } finally {
      win32.CloseHandle(handle);
    }
  } catch (_) {
    return true;
  }
}

bool _isProcessAlivePosix(int pid) {
  try {
    if (system.kill(pid, 0) == 0) return true;

    // errno：ESRCH(3) = 不存在；EPERM(1) = 存在但无权限（仍存活）。
    // 取值入口按 libc 分支：Linux `__errno_location`、macOS `__error`。
    final errno = Platform.isMacOS
        ? system.darwinErrno().cast<Int32>().value
        : system.errnoLocation().cast<Int32>().value;
    return errno != _esrch;
  } catch (_) {
    return true;
  }
}

/// POSIX `ESRCH`：没有这个进程。
const int _esrch = 3;
