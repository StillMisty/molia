/// 传输运行时的唯一所有者：启动 / 停止 / 回前台 / 退后台 / 本地变更公告。
///
/// 为什么单独成模块：这些动作原先分散在同步引擎（每轮开始前 ensure、释放时
/// stop、本地变更公告）与控制面（设置开关、App 生命周期），两边各有一份
/// `_ensureTransportsRunning`。同一件事两处实现，最典型的漂移是「控制面
/// 打开新传输时只启动了这一路，引擎下一轮才发现另一路还停着」；生命周期
/// 动作也会因为调用方不同而漏掉已启用判断。运行时只依赖状态存储与传输
/// 实例，不跑轮次、不碰适配器。
library;

import 'package:logging/logging.dart';

import '../../domain/ports/sync_transport.dart';
import 'sync_state_store.dart';

class SyncTransportRuntime {
  SyncTransportRuntime({
    required SyncStateStore state,
    required Map<String, SyncTransport> transports,
  })  : _state = state,
        _transports = transports;

  final SyncStateStore _state;
  final Map<String, SyncTransport> _transports;
  final Logger _logger = Logger('molia.sync');

  Map<String, SyncTransport> get transports => _transports;

  SyncTransport? transportFor(String kind) => _transports[kind];

  bool isEnabled(String kind) => _state.enabledTransports.contains(kind);

  /// 启动已启用且未运行的传输（幂等）。
  ///
  /// 启动失败由传输自己记录（`unavailableReason`）并进入本轮报告：
  /// 「开关打开但没在工作」必须能被用户看到，不能只留在日志里。
  Future<void> ensureRunning() async {
    for (final entry in _transports.entries) {
      if (!_state.enabledTransports.contains(entry.key)) continue;
      if (entry.value.isRunning) continue;
      await entry.value.start();
    }
  }

  /// 停止一路传输（关闭开关时）。
  Future<void> stop(String kind) async {
    final transport = _transports[kind];
    if (transport == null || !transport.isRunning) return;
    await transport.stop();
  }

  /// 停止全部传输（引擎释放）：不按启用状态筛选——禁用后仍可能残留运行中
  /// 的资源（例如刚在设置页关掉，stop 抛错没走完）。
  Future<void> stopAll() async {
    for (final transport in _transports.values) {
      if (!transport.isRunning) continue;
      try {
        await transport.stop();
      } catch (_) {
        // 停止失败不影响后续轮次（start 幂等）。
      }
    }
  }

  /// 回前台：通知已启用的局域网传输（隐藏过久时重绑 UDP / 探活 HTTP）。
  ///
  /// 只对实现了 [SyncLanLifecycle] 的传输调用；WebDAV 没有生命周期动作。
  /// 失败只记日志：回前台不能因为发现层异常打断调度器拉一轮。
  Future<void> onAppResumed() async {
    for (final entry in _transports.entries) {
      if (!_state.enabledTransports.contains(entry.key)) continue;
      final transport = entry.value;
      if (transport is! SyncLanLifecycle) continue;
      final lifecycle = transport as SyncLanLifecycle;
      try {
        await lifecycle.onAppResumed();
      } catch (e) {
        _logger.warning('回前台：传输 ${entry.key} 恢复失败', e);
      }
    }
  }

  /// 退后台：通知已启用的局域网传输取消公告 / 重连计时器。
  void onAppHidden() {
    for (final entry in _transports.entries) {
      if (!_state.enabledTransports.contains(entry.key)) continue;
      final transport = entry.value;
      if (transport is! SyncLanLifecycle) continue;
      final lifecycle = transport as SyncLanLifecycle;
      try {
        lifecycle.onAppHidden();
      } catch (e) {
        _logger.warning('退后台：传输 ${entry.key} 暂停失败', e);
      }
    }
  }

  /// 本地变更但本轮推送零对端：对指定传输发一次定向公告（只单播）。
  ///
  /// 只有实现了 [SyncLanLifecycle] 的传输有公告能力；失败只记日志（公告是
  /// 「加速」而不是正确性前提）。返回是否真的发给了传输。
  Future<bool> announceLocalChange(String kind) async {
    if (!_state.enabledTransports.contains(kind)) return false;
    final transport = _transports[kind];
    if (transport is! SyncLanLifecycle) return false;
    final lifecycle = transport as SyncLanLifecycle;
    try {
      await lifecycle.announceLocalChange();
      return true;
    } catch (e) {
      _logger.fine(() => '本地变更公告失败: $e');
      return false;
    }
  }
}
