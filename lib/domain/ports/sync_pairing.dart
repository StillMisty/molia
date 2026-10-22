/// 局域网附近设备配对端口：UI 只依赖这个接口，不接触 HTTP / UDP / 加密实现。
///
/// 生命周期与局域网传输绑定：传输停止后 [startScan] 失败、请求返回
/// `unavailable`；后台 / 锁屏 / 省电 / 蜂窝下接收方不弹窗（由实现检查
/// 组合根注入的前台判定）。
library;

import '../models/sync_nearby_pairing.dart';

abstract interface class SyncPairingPort {
  /// 附近设备快照流（候选 TTL 15s；每次变化推一份不可变列表）。
  Stream<List<SyncNearbyDevice>> get nearbyDevices;

  /// 接收方待确认请求流：同一时间只展示一个（队列里的其余请求不推送）。
  Stream<SyncPairingRequest> get incomingRequests;

  /// 发起方尝试状态流（确认码 / 等待 / 最终结局）。
  Stream<SyncPairingAttempt> get attempts;

  /// 当前是否在主动探测附近设备。
  bool get scanning;

  /// 本机是否已有同步组（由组合根按「已配对设备 / 成功接触」判定）。
  bool get hasGroup;

  /// 开始扫描（同步页打开时调用）。后台 / 蜂窝 / 传输停止时返回 false。
  Future<bool> startScan();

  /// 向指定地址单播一条 MSP 探测（手动地址兜底）。
  ///
  /// [probePort] 为 0 时使用 `ManualPeer.defaultProbePort`；地址 / 端口非法、
  /// 后台 / 蜂窝策略拒绝或发送失败都返回 false。
  Future<bool> probeAddress(String host, {int probePort = 0});

  /// 停止扫描并清空附近候选（同步页关闭时调用）。
  void stopScan();

  /// 向附近设备发起配对；完成时返回类型化结局（等待期间经 [attempts] 推送
  /// 确认码与状态）。同一时间只允许一个发起方尝试。
  Future<SyncPairingResult> requestPairing(SyncNearbyDevice device);

  /// 接收方接受 / 拒绝一条请求。
  Future<SyncPairingOutcome> respond(
    String requestId, {
    required bool accept,
  });

  /// 取消发起方尚未完成的尝试（本地动作，不再等待对端）。
  Future<void> cancelPairing(String requestId);

  /// 释放定时器 / 流 / HTTP 客户端（重复调用幂等）。
  Future<void> dispose();
}
