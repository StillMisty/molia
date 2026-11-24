/// 启动期状态对象 ↔ Riverpod 快照的桥接（Riverpod 半边）。
///
/// 契约本身（`SnapshotSource` / `SnapshotSignal`）在
/// `lib/utils/snapshot_source.dart`：数据层与播放层不得 import providers，
/// 但它们的启动期对象同样要实现这套契约。UI 侧统一经 [SnapshotNotifier]
/// 读快照；命令仍落在对象自己身上（经 `xxxControllerProvider` 取实例）。
///
/// 为什么状态不在 Notifier 里：这些对象与启动顺序、平台通道、服务生命周期
/// 强耦合（见 ADR-0041 §2「服务不改成 Notifier」），容器只镜像它们的快照。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/bootstrap/runtime_providers.dart';
import '../utils/snapshot_source.dart';

export '../utils/snapshot_source.dart';

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
