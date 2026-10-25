/// 类型化拉取计划的数据形状（传输端口契约的一部分）。
///
/// 计划由引擎每轮生成一次：逐对端携带本机游标与「强制全量」意图，外加发现
/// 策略；传输只负责取证据并按 `data/sync/sync_pull_plan.dart` 的统一判定
/// 执行。放在 domain 是因为 [SyncPullRequest] 直接持有它，而 domain 不能
/// 反向依赖 data。
library;

/// 发现策略（轮次级，不是逐对端动作）。
///
/// 发现只有局域网有：普通轮次只单播已知候选，启动 / 回前台 / 换网 / 手动轮
/// 才广播 + 组播。WebDAV 没有发现通道，消费计划时忽略这一项。
enum SyncPullDiscovery { knownOnly, full }

/// 引擎对一台对端的拉取意图（来自名册游标与 anti-entropy / 缺口名单）。
class SyncPeerPullIntent {
  const SyncPeerPullIntent({
    required this.deviceId,
    required this.cursor,
    this.forceFull = false,
  });

  final String deviceId;

  /// 本机已消费该对端 journal 的位置（-1 = 尚未消费过）。
  final int cursor;

  /// 强制全量（权威视图兜底）。
  final bool forceFull;

  @override
  String toString() =>
      'SyncPeerPullIntent($deviceId, cursor: $cursor, full: $forceFull)';
}

/// 一轮的拉取计划：引擎生成一次，所有传输消费同一份。
class SyncPullPlan {
  const SyncPullPlan({
    this.discovery = SyncPullDiscovery.knownOnly,
    this.peers = const {},
  });

  SyncPullPlan.fromIntents({
    required Iterable<SyncPeerPullIntent> intents,
    this.discovery = SyncPullDiscovery.knownOnly,
  }) : peers = {for (final intent in intents) intent.deviceId: intent};

  /// 普通轮次：单播已有候选，不广播。
  static const SyncPullPlan none = SyncPullPlan();

  final SyncPullDiscovery discovery;

  /// 对端 id → 意图。计划里没有的对端（本轮新发现 / 远端目录里的新设备）
  /// 按「无游标、不强制全量」处理。
  final Map<String, SyncPeerPullIntent> peers;

  bool get isEmpty => peers.isEmpty && discovery == SyncPullDiscovery.knownOnly;

  bool get forceDiscovery => discovery == SyncPullDiscovery.full;

  int cursorFor(String deviceId) =>
      peers[deviceId]?.cursor ?? SyncPullRequestCursor.none;

  bool forcesFull(String deviceId) => peers[deviceId]?.forceFull ?? false;

  SyncPeerPullIntent intentFor(String deviceId) =>
      peers[deviceId] ??
      SyncPeerPullIntent(
        deviceId: deviceId,
        cursor: SyncPullRequestCursor.none,
      );
}

/// 拉取请求的常量（避免计划模块反向依赖端口文件）。
abstract final class SyncPullRequestCursor {
  /// 未记录过的对端：尚未消费任何条目。
  static const int none = -1;
}
