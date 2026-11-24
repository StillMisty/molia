/// 启动期状态对象的快照契约（与 Riverpod 无关的中性层）。
///
/// 组合根（`lib/app/bootstrap/`）按启动顺序构造的业务对象不再继承
/// `ChangeNotifier`：自己持有可变字段，通过 [SnapshotSource.state] 暴露
/// **不可变快照**，通过 [SnapshotSource.changes] 发出变更信号。
///
/// 放在 `lib/utils/` 是因为 `lib/sources/` 等底层模块也要实现它，而分层规则
/// 不允许它们 import `lib/providers/`。Riverpod 侧的镜像（`SnapshotNotifier`
/// / `snapshotController`）在 `lib/providers/snapshot_source.dart`，并转出本文件。
library;

import 'package:flutter/foundation.dart';

/// 可镜像到 Riverpod 的启动期状态对象。
abstract interface class SnapshotSource<S> {
  /// 当前快照；[changes] 每次通知后由 provider 重新读取。
  S get state;

  /// 变更信号（替代 `ChangeNotifier.notifyListeners` 的订阅面）。
  Listenable get changes;
}

/// 最小变更信号：只负责通知，不持有任何状态。
///
/// 用它可以保留 `Listenable` / `ValueListenable` 的既有接口（播放服务、
/// 原生窗口回调），同时不再把状态锁进 `ChangeNotifier`。
class SnapshotSignal implements Listenable {
  final List<VoidCallback> _listeners = <VoidCallback>[];

  @override
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  /// 通知所有订阅者；通知期间的增删在副本上迭代。
  void notify() {
    if (_listeners.isEmpty) return;
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }
}
