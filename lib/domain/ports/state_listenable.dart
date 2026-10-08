/// 领域层只读可监听值（纯 Dart，等价 Flutter `ValueListenable<T>` 的最小子集）。
///
/// 为什么不复用 `package:flutter/foundation.dart` 的 `ValueListenable`：
/// docs/architecture.md §2.1 硬性规则禁止 `lib/domain/**` import Flutter。
/// 数据层实现直接继承 `ValueNotifier<T>` 并实现本接口，
/// 同一对象同时满足领域端口与 Flutter 生态（`ValueListenableBuilder` 等）。
abstract interface class StateListenable<T> {
  T get value;
  void addListener(void Function() listener);
  void removeListener(void Function() listener);
}
