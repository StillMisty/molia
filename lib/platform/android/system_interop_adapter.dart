/// Android JNI 系统查询适配器（ADR-0038 阶段 2）。
///
/// 只做平台守卫、类型投影与失败静默：生成的 JNI 绑定（`system_interop.g.dart`）
/// 与 Kotlin `SystemInterop` 一一对应，业务层不直接 import 本文件。
library;

import 'dart:io' show Platform;

import 'system_interop.g.dart' as jni;

/// 电池快照：`level` 为百分比（0–100，-1 = 未知），其余为充电 / 系统省电模式。
///
/// 非 Android、JNI 类加载失败或数组结构异常时返回 null，调用方按「未知」
/// 降级（与通道版语义一致）。
({int level, bool charging, bool powerSave})? readBatterySnapshot() {
  if (!Platform.isAndroid) return null;
  try {
    final array = jni.SystemInterop.batterySnapshot();
    try {
      if (array.length < 3) return null;
      // getRange 复制到 Dart 侧 Int64List；JLongArray 本身是全局引用，
      // 必须显式 release（10k 次基准里泄漏会造成全局引用表膨胀）。
      final values = array.getRange(0, 3);
      return (
        level: values[0],
        charging: values[1] == 1,
        powerSave: values[2] == 1,
      );
    } finally {
      array.release();
    }
  } catch (_) {
    return null;
  }
}

/// 应用私有文件所在分区总容量（字节）；非 Android / 失败返回 null。
///
/// Kotlin 侧未知值是 -1，这里统一折算成 null，让上层回退默认缓存上限。
int? readTotalSpaceBytes() {
  if (!Platform.isAndroid) return null;
  try {
    final bytes = jni.SystemInterop.totalBytes();
    return bytes > 0 ? bytes : null;
  } catch (_) {
    return null;
  }
}
