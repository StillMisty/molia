/// 同步状态的窄接口（sync book 第一片）。
///
/// 为什么拆：`SyncStateStore` 既是持久化实现、又是所有同步模块的依赖汇聚点
/// （~55 个公开成员）。适配器只关心登记哈希与版本发号器，发布台账只关心
/// 快照覆盖位置，轮次编排只关心身份 / 开关 / 名册，引擎只关心生命周期与
/// 一次提交。按用途声明窄接口后，模块的构造函数就是它的真实依赖，评审与
/// 测试不必再从整份状态里挑字段。
///
/// 这里只收窄**依赖形状**：实现仍是唯一的 `SyncStateStore`，状态 JSON 的
/// 键、形状与写入顺序都不变（形状定义在 `sync_state_codec.dart`）；持久化
/// 只有一个出口 [SyncCommitter.commit]。
library;

import '../../domain/models/device_sync.dart';
import 'sync_stamp.dart';

/// 名册保留设备数（按最近接触时间淘汰；状态持久化与轮次名册共用）。
const int syncPeerLimit = 20;

/// 持久化的唯一出口（轮末 / 生命周期事件 / 用户命令）。
///
/// 实现按脏标记合并写入：一轮内的多次内存变更只落一次盘。
abstract interface class SyncCommitter {
  /// 把当前内存状态写入持久层；没有变化时是空操作。
  Future<void> commit();
}

/// 适配器的登记面：变更检测、版本登记与增量日志追加所需的最小读写。
///
/// 写入登记（`put*` / `set*`）只改内存并标脏，由轮末提交统一落盘；适配器
/// 必须先确认日志追加成功再写登记（否则「已同步」的登记会掩盖丢失的变更）。
abstract interface class SyncStampLedger {
  /// 本机所有同步戳的唯一发号器。
  SyncStampIssuer get stampIssuer;

  /// 设置键 → 登记哈希 + 版本。
  Map<String, SyncStamp> get settingStamps;

  /// 脚本 id → 内容哈希 + 版本。
  Map<String, SyncStamp> get scriptStamps;

  /// 脚本 id → 删除墓碑。
  Map<String, SyncStamp> get scriptTombstones;

  /// 上轮收集到的脚本 id（本地删除检测的基线）。
  List<String> get knownScriptIds;

  /// 激活脚本指针的登记。
  SyncStamp? get activeScriptStamp;

  /// 上次播放会话的登记。
  SyncStamp? get sessionStamp;

  /// 自定义封面键 → 内容哈希 + 版本（本地变化检测）。
  Map<String, SyncStamp> get coverStamps;

  /// 自定义封面键 → 删除墓碑。
  Map<String, SyncStamp> get coverTombstones;

  int nowMs();

  void putSettingStamp(String key, SyncStamp stamp);

  void putScriptStamp(String id, SyncStamp stamp);

  void removeScriptStamp(String id);

  void putScriptTombstone(String id, SyncStamp stamp);

  void removeScriptTombstone(String id);

  void setKnownScriptIds(Iterable<String> ids);

  void setActiveScriptStamp(SyncStamp? stamp);

  void setSessionStamp(SyncStamp? stamp);

  void putCoverStamp(String key, SyncStamp stamp);

  void removeCoverStamp(String key);

  void putCoverTombstone(String key, SyncStamp stamp);

  void removeCoverTombstone(String key);
}

/// 发布台账的持久覆盖面（`sync_state_v2` 的 `snapshotPushSeq`）。
///
/// 只改内存并标脏：发布台账在推送循环里逐传输 / 逐载荷记账，本轮结束由
/// 引擎提交一次，避免多对端一轮写多次大状态 JSON。
abstract interface class SyncPublicationState {
  /// 传输最近成功发布的全量快照覆盖位置（-1 = 尚未发布）。
  int snapshotPushSeq(String kind);

  /// 记录新的覆盖位置（内存 + 标脏）。
  void setSnapshotPushSeq(String kind, int seq);
}

/// 轮次编排所需的状态面：身份、类别 / 传输开关、口令与名册观测。
abstract interface class SyncRoundState implements SyncPublicationState {
  String get deviceId;

  String get deviceName;

  Set<SyncCategory> get enabledCategories;

  Set<String> get enabledTransports;

  /// 名册（按最近接触时间倒序；本机不在其中）。
  List<SyncPeerState> get peers;

  Future<String?> readPassphrase();
}

/// 同步引擎所需的状态面：生命周期、身份、名册与一轮一次的提交。
abstract interface class SyncEngineState implements SyncCommitter {
  bool get enabled;

  String get deviceId;

  Set<SyncCategory> get enabledCategories;

  /// 是否需要清空可再生的派生状态（见 `SyncStateStore.freshInstall`）。
  bool get freshInstall;

  Future<void> init();

  Future<void> markFreshHandled();

  List<SyncPeerState> get peers;

  bool isPeerConnectNotified(String deviceId);

  /// 登记「首次连通」已提示（只改内存 + 标脏；随轮末提交落盘）。
  void markPeerConnectNotified(String deviceId);

  /// 记录一轮同步结果（日志 + 名册；只改内存 + 标脏）。
  void recordRound(SyncRoundReport report);
}

/// 传输运行时所需的状态面。
abstract interface class SyncTransportState {
  Set<String> get enabledTransports;
}

/// 调度器所需的状态面（频率 / 类别 / 发现目标）。
abstract interface class SyncSchedulerState {
  SyncCellularPolicy get cellularPolicy;

  Set<SyncCategory> get enabledCategories;

  Set<String> get enabledTransports;

  List<LanPeerEndpoint> get lanEndpoints;

  List<ManualPeer> get manualPeers;
}

/// 完整备份所需的状态面（身份 + 导入后的提交）。
abstract interface class SyncBackupState implements SyncCommitter {
  String get deviceId;

  String get deviceName;
}
