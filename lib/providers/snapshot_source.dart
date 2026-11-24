/// 启动期状态对象 ↔ Riverpod 快照的桥接契约。
///
/// 组合根（`lib/app/bootstrap/`）按启动顺序构造的业务对象不再继承
/// `ChangeNotifier`：自己持有可变字段，通过 [state] 暴露**不可变快照**，
/// 通过 [changes] 发出变更信号。UI 侧统一经 [SnapshotNotifier] 读快照；
/// 命令仍落在对象自己身上（经 `xxxControllerProvider` 取实例）。
///
/// 为什么状态不在 Notifier 里：这些对象与启动顺序、平台通道、服务生命周期
/// 强耦合（见 ADR-0041 §2「服务不改成 Notifier」），容器只镜像它们的快照。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/bootstrap/runtime_providers.dart';

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

/// 把启动期实例的不可变快照镜像成 Riverpod `Notifier<State>`。
class SnapshotNotifier<C extends SnapshotSource<S>, S> extends Notifier<S> {
  SnapshotNotifier(this._resolve);

  final C Function(Ref ref) _resolve;

  late C _source;

  @override
  S build() {
    final source = _resolve(ref);
    _source = source;
    source.changes.addListener(_onChanged);
    ref.onDispose(() => source.changes.removeListener(_onChanged));
    return source.state;
  }

  void _onChanged() => state = _source.state;
}

/// 同 [SnapshotNotifier]，但依赖可能未接线（设置页等可选入口）。
class NullableSnapshotNotifier<C extends SnapshotSource<S>, S>
    extends Notifier<S?> {
  NullableSnapshotNotifier(this._resolve);

  final C? Function(Ref ref) _resolve;

  C? _source;

  @override
  S? build() {
    final source = _resolve(ref);
    _source = source;
    if (source == null) return null;
    source.changes.addListener(_onChanged);
    ref.onDispose(() => source.changes.removeListener(_onChanged));
    return source.state;
  }

  void _onChanged() {
    final source = _source;
    if (source != null) state = source.state;
  }
}

/// 启动期实例访问面：`ref.read(xControllerProvider).command()`。
///
/// 读快照走 [SnapshotNotifier]（`xProvider`），写 / 命令走这里；两者指向
/// 组合根登记的同一实例。
Provider<C> snapshotController<C extends Object>() =>
    Provider<C>((ref) => ref.read(appRuntimeProvider).require<C>());

/// 同 [snapshotController]，但允许「未接线」（设置页等可选入口）。
Provider<C?> maybeSnapshotController<C extends Object>() =>
    Provider<C?>((ref) => ref.read(appRuntimeProvider).maybe<C>());
