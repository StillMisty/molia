/// 已配对设备的连接状态判定（纯函数，不碰 UI / 传输）。
///
/// 状态的事实来源只有名册：`lastSuccessAt` = 最近一次真正接触成功，
/// `lastSeenAt` = 最近一次尝试（含失败）。只有本轮报告能回答「这次尝试发生在
/// 最新一轮里吗」——因此调用方必须把手边最新的 [SyncRoundReport] 传进来。
library;

import 'device_sync.dart';

/// 一台设备在当前观测下的连接状态（设置页设备行据此选文案）。
enum SyncPeerConnectionStatus {
  /// 最近一轮里真正接触成功（探测应答 / 未变跳过 / 数据流转成功）。
  connected,

  /// 最近一轮尝试过但没有成功。
  unreachable,

  /// 有历史接触证据，但最近一轮没有尝试它。
  idle,

  /// 从未有过任何接触证据。
  never,

  /// 超过 180 天没有成功接触。
  lost,
}

/// 解析设备状态。
///
/// - [report] 为 null（本次进程还没跑过一轮）时，只能用持久化名册判断：
///   有失败原因按未连接，否则按「上次同步」；
/// - 失联优先于其它状态：即使最近一份报告是旧的，也不能把超过 180 天没有
///   成功接触的设备说成已连接；
/// - 旧名册没有 `lastSuccessAt` 时用 [SyncPeerState.effectiveLastSuccessAt]
///   兜底（数据流转时间 → 无失败的最后尝试），升级后不会一律显示「还没连上」。
SyncPeerConnectionStatus resolveSyncPeerConnection(
  SyncPeerState peer, {
  SyncRoundReport? report,
  required int nowMs,
}) {
  if (peer.isLostAt(nowMs)) return SyncPeerConnectionStatus.lost;

  final successAt = peer.effectiveLastSuccessAt;
  final attemptAt = peer.lastSeenAt;
  final hasEvidence = successAt > 0 || attemptAt > 0 || peer.lastError != null;
  if (!hasEvidence) return SyncPeerConnectionStatus.never;

  final startedAt = report?.startedAt;
  if (startedAt == null) {
    return peer.lastError == null
        ? SyncPeerConnectionStatus.idle
        : SyncPeerConnectionStatus.unreachable;
  }
  if (successAt >= startedAt) return SyncPeerConnectionStatus.connected;
  if (attemptAt >= startedAt) return SyncPeerConnectionStatus.unreachable;
  return SyncPeerConnectionStatus.idle;
}
