/// jnigen 1.1.0 生成物与 `package:jni` 1.1.2 的兼容垫片。
///
/// jnigen 1.1.0 生成 `.g.jni.dart` 时调用 `JReference.nonNullPointer`，该成员
/// 只存在于尚未发布的 `package:jni` 1.2.0。这里按 1.2.0 的实现补一份扩展
/// （`pointer` + null 检查），由 `tool/pigeon/generate.sh` 在生成后 import。
///
/// 移除条件：`package:jni` 发布 1.2.0、`pubspec.yaml` 升级后删除本文件与
/// 生成脚本里的 import 补丁。
library;

import 'dart:ffi' show Pointer, nullptr, Void;

import 'package:jni/jni.dart';

extension JniNonNullPointerCompat on JReference {
  /// 与 jni 1.2.0 的 `JReference.nonNullPointer` 语义一致：空引用抛
  /// [JNullError]，否则返回底层 jobject 指针。
  Pointer<Void> get nonNullPointer {
    final pointer = this.pointer;
    if (pointer == nullptr) throw JNullError();
    return pointer;
  }
}
