/// Linux 默认 sink 的纯决策（ADR-0036）。
///
/// 把「这条 `pactl` 事件要不要刷新 / 暂停」与「刷新后的快照是否意味着旧默认
/// 消失」从进程 I/O 中拆出来：`PactlOutputWatcher` 只负责跑 `pactl`、解析行，
/// 决策全部在这里，CI 不需要声音服务器。
library;

import 'pactl_sink_events.dart';

/// 一次成功 `pactl list short sinks` + 默认 sink 查询的结果。
///
/// [defaultSinkKnown] 为 false 表示默认 sink 查询失败（命令不存在 / 无服务
/// 器 / 超时）：此时 [defaultSink] 不可信，tracker 必须保留上一默认值，不能
/// 因为一次瞬时失败永久失去检测能力。
class PactlSinkSnapshot {
  const PactlSinkSnapshot({
    required this.sinkNamesById,
    required this.defaultSink,
    this.defaultSinkKnown = true,
  });

  final Map<int, String> sinkNamesById;
  final String? defaultSink;
  final bool defaultSinkKnown;
}

/// 事件之后 watcher 应该做的 I/O 与是否立即上报。
class PactlSinkEventAction {
  const PactlSinkEventAction({
    required this.refresh,
    required this.notifyIfDefaultMissing,
    required this.emitOutputLost,
  });

  /// 无需刷新快照（如 source / sink-input 的 remove）。
  static const PactlSinkEventAction none = PactlSinkEventAction(
    refresh: false,
    notifyIfDefaultMissing: false,
    emitOutputLost: false,
  );

  final bool refresh;

  /// 刷新后若旧默认 sink 名已不在列表里，是否上报输出丢失。
  final bool notifyIfDefaultMissing;

  /// 已知被移除的 sink 就是当前默认 sink：立即上报（刷新只更新快照）。
  final bool emitOutputLost;
}

/// 跟踪默认 sink 名与 sink id→name 表，回答事件与快照的语义。
class PactlSinkTracker {
  Map<int, String> _sinkNamesById = const <int, String>{};
  String? _defaultSink;

  /// 当前跟踪的默认 sink 名；查询失败时保留上一次成功值。
  String? get defaultSink => _defaultSink;

  Map<int, String> get sinkNamesById => _sinkNamesById;

  /// 事件 → watcher 动作。只读当前状态，不改快照。
  PactlSinkEventAction onEvent(PactlEvent event) {
    switch (event.facility) {
      case 'server':
        // 默认 sink 切换 / 服务器状态变化：刷新；若旧默认名已从 sink 列表
        // 消失（部分服务器先发 change 再发 remove），按输出丢失处理。
        if (event.kind == PactlEventKind.changed ||
            event.kind == PactlEventKind.added) {
          return const PactlSinkEventAction(
            refresh: true,
            notifyIfDefaultMissing: true,
            emitOutputLost: false,
          );
        }
      case 'sink':
        if (event.kind == PactlEventKind.removed) {
          final removedName = event.id == null
              ? null
              : _sinkNamesById[event.id];
          final wasDefault = removedName != null && removedName == _defaultSink;
          // 已知默认 sink 被移除时只刷新快照（避免同一事件重复上报）；
          // id 不在表里时才靠「旧默认名已从列表消失」兜底。
          return PactlSinkEventAction(
            refresh: true,
            notifyIfDefaultMissing: !wasDefault,
            emitOutputLost: wasDefault,
          );
        }
        if (event.kind == PactlEventKind.added ||
            event.kind == PactlEventKind.changed) {
          // 新增 / 变化只刷新，不暂停：用户可能只是主动切换输出。
          return const PactlSinkEventAction(
            refresh: true,
            notifyIfDefaultMissing: false,
            emitOutputLost: false,
          );
        }
      default:
        // source / sink-input / client / card 等与播放输出无关。
        break;
    }
    return PactlSinkEventAction.none;
  }

  /// 应用一次刷新结果；返回「旧默认 sink 名已不在新快照里」。
  ///
  /// [PactlSinkSnapshot.defaultSinkKnown] 为 false 时保留旧默认值。旧默认值为
  /// null / 空（启动时尚无默认）不算丢失。
  bool applySnapshot(PactlSinkSnapshot snapshot) {
    final previousDefault = _defaultSink;
    _sinkNamesById = Map<int, String>.unmodifiable(snapshot.sinkNamesById);
    if (snapshot.defaultSinkKnown) {
      _defaultSink = snapshot.defaultSink;
    }
    return previousDefault != null &&
        previousDefault.isNotEmpty &&
        !_sinkNamesById.containsValue(previousDefault);
  }
}
