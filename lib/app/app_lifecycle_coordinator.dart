import 'dart:async';

/// 一个子系统对应用前后台事件的反应。
///
/// 三个钩子分开注册（而不是一个 `onState`）：同步在 pause 与 hide 都要收
/// 传输，播放会话提交与统计落盘只认 pause；合成一个事件会让桌面 `hide`
/// 多提交一次会话（现行为明确避免这一点）。
class AppLifecycleParticipant {
  const AppLifecycleParticipant({this.onResumed, this.onPaused, this.onHidden});

  final FutureOr<void> Function()? onResumed;
  final FutureOr<void> Function()? onPaused;
  final FutureOr<void> Function()? onHidden;
}

/// 应用生命周期扇出的唯一 owner：main 只把系统事件转给这里。
///
/// 各子系统注册自己的动作（同步 / 会话 / 统计 / 网络刷新 / 更新），
/// 避免 `main.dart` 与 `app_shell.dart` 各持一份 `WidgetsBindingObserver`
/// 造成同一事件在不同时机被多发或漏发。
class AppLifecycleCoordinator {
  final List<AppLifecycleParticipant> _participants = [];

  void register(AppLifecycleParticipant participant) {
    _participants.add(participant);
  }

  /// 回前台：并发启动所有回调（保持旧接线「不互相等待」的语义）。
  Future<void> resumed() => _fanOut((p) => p.onResumed);

  /// 进入后台（paused）：只通知显式注册了 pause 动作的子系统。
  Future<void> paused() => _fanOut((p) => p.onPaused);

  /// 不可见（paused / hidden / 桌面托盘隐藏）：通知同步等「停后台工作」的
  /// 子系统；不触发会话提交。
  Future<void> hidden() => _fanOut((p) => p.onHidden);

  Future<void> _fanOut(
    FutureOr<void> Function()? Function(AppLifecycleParticipant) select,
  ) async {
    final pending = <Future<void>>[];
    for (final participant in List<AppLifecycleParticipant>.of(_participants)) {
      final callback = select(participant);
      if (callback == null) continue;
      pending.add(_invoke(callback));
    }
    if (pending.isNotEmpty) await Future.wait(pending);
  }

  static Future<void> _invoke(FutureOr<void> Function() callback) async {
    await callback();
  }

  /// 进程退出 / 测试拆卸：清掉注册表，避免持有已销毁子系统。
  void dispose() => _participants.clear();
}
