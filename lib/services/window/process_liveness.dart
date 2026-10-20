/// 进程存活探测：只用于单实例陈旧锁的快速判定。
///
/// 强杀 / 更新器终止应用会留下 `single_instance.lock`；若直接连旧的 loopback
/// 端口，Windows 上可能要等满 2s 连接超时才开始重抢，首帧被白等。这里改为
/// 先问操作系统「这个 pid 还在不在」，pid 已退出就立刻清锁重抢。
///
/// 窗口能力只在 Linux / Windows 使用（`WindowChrome.isSupported`）；其它平台
/// 保守返回 true，不参与该路径。
library;

import 'dart:ffi';
import 'dart:io';

/// 目标 pid 是否仍存活。
///
/// 查询失败 / 权限不足时保守返回 true：宁可多等一次连接，也不要误删活实例
/// 的锁、多开一个窗口。
bool isProcessAlive(int pid) {
  if (pid <= 0) return false;
  if (Platform.isWindows) return _isProcessAliveWindows(pid);
  if (Platform.isLinux) return _isProcessAliveLinux(pid);
  return true;
}

bool _isProcessAliveWindows(int pid) {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final openProcess = kernel32.lookupFunction<
        IntPtr Function(Uint32, Int32, Uint32),
        int Function(int, int, int)>('OpenProcess');
    final waitForSingleObject = kernel32.lookupFunction<
        Uint32 Function(IntPtr, Uint32),
        int Function(int, int)>('WaitForSingleObject');
    final closeHandle = kernel32.lookupFunction<Int32 Function(IntPtr),
        int Function(int)>('CloseHandle');
    final getLastError = kernel32.lookupFunction<Uint32 Function(),
        int Function()>('GetLastError');

    // SYNCHRONIZE：只需要等进程退出，不需要读它的内存。
    final handle = openProcess(0x00100000, 0, pid);
    if (handle == 0) {
      // ERROR_ACCESS_DENIED（5）：进程存在但无权打开，按存活处理；
      // ERROR_INVALID_PARAMETER（87）等其它错误才视为已退出。
      return getLastError() == 5;
    }
    try {
      final result = waitForSingleObject(handle, 0);
      // WAIT_TIMEOUT：未退出；WAIT_OBJECT_0：已退出；
      // WAIT_FAILED：查询失败，保守按存活处理。
      return result == 0x102 || result == 0xFFFFFFFF;
    } finally {
      closeHandle(handle);
    }
  } catch (_) {
    return true;
  }
}

bool _isProcessAliveLinux(int pid) {
  try {
    final kill = DynamicLibrary.process().lookupFunction<
        Int32 Function(Int32, Int32),
        int Function(int, int)>('kill');
    if (kill(pid, 0) == 0) return true;

    // errno：ESRCH(3) = 不存在；EPERM(1) = 存在但无权限（仍存活）。
    final errnoLocation = DynamicLibrary.process().lookupFunction<
        Pointer<Int32> Function(),
        Pointer<Int32> Function()>('__errno_location');
    return errnoLocation().value != 3;
  } catch (_) {
    return true;
  }
}
