/// 音源引擎随网络恢复自愈（组合根接线件）。
///
/// 断网 / 换网时脚本的 HTTP 请求会失败，连续失败把引擎熔断到 `failed`；
/// 网络恢复后引擎不会自己醒来（下次请求要等半开冷却）。`networkEvents` 是
/// 系统给出的「网络确实变了」信号，比用户恰好点开音源页更可靠。
///
/// 只在引擎处于 `failed` 时动作（普通网络抖动不碰引擎）；`retryEngine`
/// 自身 single-flight，事件连发只会合并成一次恢复尝试。
library;

import 'dart:async';

import '../../sources/source_manager.dart';

class SourceEngineNetworkRecovery {
  SourceEngineNetworkRecovery({
    required SourceManager sourceManager,
    required Stream<void> networkEvents,
  }) {
    _subscription = networkEvents.listen((_) {
      if (!sourceManager.engineFailed) return;
      unawaited(sourceManager.retryEngine());
    });
  }

  late final StreamSubscription<void> _subscription;

  /// 取消网络事件订阅（跟随 root 的进程销毁生命周期）。
  Future<void> dispose() => _subscription.cancel();
}
