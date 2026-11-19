/// 把已 free / 可换出的页交还系统（ADR-0038）。
///
/// - Linux/glibc：`malloc_trim(0)` 归还 arena 的空闲页；
/// - macOS：`malloc_zone_pressure_relief(NULL, 0)` 让所有 zone 归还空闲页；
/// - Windows：`EmptyWorkingSet` 把工作集里可换出的页移出。任务管理器的
///   「内存」列是专用工作集（不是已 free 字节数），free 后不会自动缩；
///   这里只影响工作集，「提交大小」仍由调用方的图片缓存清理决定。
///
/// mpv 自带 allocator 与 Dart 堆不受这里影响，只解决 allocator / 页表这一层。
/// 平台或符号不可用时静默跳过：这是尽力而为的补充，不能影响释放逻辑本身。
library;

import 'dart:ffi' show nullptr;
import 'dart:io' show Platform;

import 'package:win32/win32.dart' as win32;

import 'system_ffi.g.dart' as system;

/// 按平台把空闲页交还系统；失败静默。
void releaseFreedMemoryToOs() {
  if (Platform.isLinux) {
    try {
      system.malloc_trim(0);
    } catch (_) {
      // musl / 静态链接等场景没有该符号：跳过即可。
    }
    return;
  }
  if (Platform.isMacOS) {
    try {
      // zone = NULL：对所有 zone 生效；goal = 0：尽力归还全部可释放页。
      system.malloc_zone_pressure_relief(nullptr, 0);
    } catch (_) {
      // 符号缺失（极少见）：跳过，系统仍会在内存压力下自行回收。
    }
    return;
  }
  if (Platform.isWindows) {
    try {
      // 伪句柄 = 当前进程（GetCurrentProcess）。
      win32.EmptyWorkingSet(win32.GetCurrentProcess());
    } catch (_) {
      // psapi 不可用 / 符号缺失：跳过；系统仍会在内存压力下自行回收。
    }
  }
}
