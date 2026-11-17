part of 'app_shell.dart';

/// 应用壳接收方配对请求的串行队列。
///
/// 服务在一条请求被应答后会立刻推出下一条（`_presentNext`），而应用壳的
/// 确认窗这时可能还在关闭动画里：先入队，等当前窗真正关闭（`present`
/// 返回）后再逐条展示；宿主 context 已不存在时由 [reject] 统一给出拒绝结论。
@visibleForTesting
class IncomingPairingQueue {
  final List<SyncPairingRequest> _pending = [];
  bool _draining = false;

  bool get isDraining => _draining;
  bool get isEmpty => _pending.isEmpty;

  void add(SyncPairingRequest request) => _pending.add(request);

  /// 逐条展示队列；[present] 返回 false 表示宿主已不可用，剩余请求（含当前）
  /// 全部交给 [reject] 收口。
  Future<void> drain({
    required Future<bool> Function(SyncPairingRequest request) present,
    required Future<void> Function(SyncPairingRequest request) reject,
  }) async {
    if (_draining) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        final request = _pending.first;
        if (!await present(request)) {
          while (_pending.isNotEmpty) {
            await reject(_pending.removeAt(0));
          }
          return;
        }
        _pending.removeAt(0);
      }
    } finally {
      _draining = false;
    }
  }
}
