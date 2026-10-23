import '../models/device_sync.dart';
import '../models/sync_pull_plan.dart';

/// 一轮的显式时间窗口（pull 与 push 共用同一个起点）。
///
/// 局域网按 `presence.lastHeardAt >= 窗口起点` 判定「本轮听到的对端」：
/// 过去这个起点藏在传输的 `_roundStartedAt` 字段里，由 pull 写入、push 读取，
/// push 的正确性隐式依赖「本轮刚跑过 pull」。改成由引擎每轮创建一次并显式
/// 传给两个动作后，传输不再保存跨动作状态，单独调用 push 也有确定语义。
class SyncRoundWindow {
  const SyncRoundWindow({required this.startedAt});

  /// 本轮开始时间（毫秒时间戳）。
  final int startedAt;
}

/// 一次拉取的请求参数（增量协议：本机游标 + 需要全量兜底的对端）。
///
/// 引擎生成一份类型化的 [plan]（逐对端意图 + 发现策略），传输只负责取证据
/// 与载荷；「跳过 / 增量 / 全量」由 `decideSyncPull` 统一判定。
///
/// [cursors] / [fullPeers] / [forceDiscovery] 是旧构造方式，仍会转成同一份
/// 计划（测试与外部调用方可以继续按游标描述请求）。
class SyncPullRequest {
  const SyncPullRequest({
    Map<String, int> cursors = const {},
    Set<String> fullPeers = const {},
    bool forceDiscovery = false,
    this.window,
    SyncPullPlan? plan,
  })  : _cursors = cursors,
        _fullPeers = fullPeers,
        _forceDiscovery = forceDiscovery,
        _plan = plan;

  final Map<String, int> _cursors;
  final Set<String> _fullPeers;
  final bool _forceDiscovery;

  /// 本机已消费各对端 journal 的位置（对端 id → seq）。
  Map<String, int> get cursors => _plan?.cursors ?? _cursors;

  /// 强制走全量快照的对端 id。
  Set<String> get fullPeers => _plan?.fullPeers ?? _fullPeers;

  /// 强制做一次完整发现（广播 + 组播 + 单播；启动 / 回前台 / 换网 / 手动）。
  ///
  /// 普通轮次只对已有候选单播，避免空闲时反复广播耗电。
  bool get forceDiscovery => _plan?.forceDiscovery ?? _forceDiscovery;

  /// 本轮时间窗口（pull → push 显式共享；null = 传输自行取当前时间）。
  final SyncRoundWindow? window;

  final SyncPullPlan? _plan;

  /// 未记录过的对端：尚未消费任何条目。
  static const int noCursor = SyncPullRequestCursor.none;

  static const SyncPullRequest none = SyncPullRequest();

  /// 类型化拉取计划：引擎显式给计划时原样使用，否则按旧字段构造。
  SyncPullPlan get plan =>
      _plan ??
      SyncPullPlan.fromIntents(
        discovery: _forceDiscovery
            ? SyncPullDiscovery.full
            : SyncPullDiscovery.knownOnly,
        intents: [
          for (final entry in _cursors.entries)
            SyncPeerPullIntent(
              deviceId: entry.key,
              cursor: entry.value,
              forceFull: _fullPeers.contains(entry.key),
            ),
          for (final id in _fullPeers)
            if (!_cursors.containsKey(id))
              SyncPeerPullIntent(
                deviceId: id,
                cursor: noCursor,
                forceFull: true,
              ),
        ],
      );

  int cursorFor(String deviceId) =>
      _plan?.cursorFor(deviceId) ?? _cursors[deviceId] ?? noCursor;
}

/// 一次拉取的结果。
///
/// 失败按宽容处理（不抛异常）：单个对端的网络 / 解密失败只计入 [failedPeers]，
/// 其余对端的结果照常返回。[peersSeen] 是本轮实际探测到 / 列出的对端数——
/// 「一个对端都没发现」与「没有变化」必须能被上层区分开。
///
/// [failedIssues] 把失败及原因落到具体设备（名册据此写 `lastError` 且不刷新
/// 成功时间）；[failedPeers] 保持「预期对端失败计数」的旧语义，二者不是同一
/// 件事：只有持久化端点的试探性对端失败会进 [failedIssues]，但不计入
/// [failedPeers]。
///
/// [envelopes] 同时承载两种载荷：增量窗口（`isDelta`）与 bootstrap 全量快照；
/// 引擎按载荷形态分别推进游标与合并。
class SyncPullResult {
  const SyncPullResult({
    this.envelopes = const [],
    this.peersSeen = 0,
    this.skippedUnchanged = 0,
    this.failedPeers = 0,
    this.bytesIn = 0,
    this.contacted = false,
    this.seenIds = const [],
    this.failedIssues = const {},
    this.error,
  });

  final List<SyncEnvelope> envelopes;

  /// 探测到 / 列出的对端数（含未变而跳过、解密失败的）。
  final int peersSeen;

  /// 远端内容未变而跳过拉取的对端数（局域网按探测应答的 `snapshotId`，
  /// WebDAV 按文件 `getetag` / `getlastmodified`）。
  final int skippedUnchanged;

  /// 拉取或解密失败的对端数。
  final int failedPeers;

  final int bytesIn;

  /// 本轮**接触过**的对端 id（含未变跳过；不含读取 / 解密失败者）。
  ///
  /// 名册的「最近接触」据此更新：在线但长期没有内容变化的对端不该被误标
  /// 失联。失败者进 [failedIssues]——读取失败不能伪装成成功接触。
  final List<String> seenIds;

  /// 本轮读取 / 解密失败的具体设备及原因（可含只有持久化端点的试探性对端）。
  ///
  /// 与 [failedPeers] 解耦：后者只统计预期对端、决定整轮 partial / failed；
  /// 这里只做名册归属，即使整轮仍是 noPeers 也要让用户知道是哪台没连上。
  /// 原因由传输按设备给出（局域网 `peerReadFailed` / `peerDecryptFailed`，
  /// WebDAV `webdavReadFailed` / `webdavDecryptFailed`），不能拿整轮第一条
  /// 错误顶替其它设备的原因。
  ///
  /// 同一设备只要有任何一次数据读取成功就不应出现在这里（局域网换地址 /
  /// 重试成功；WebDAV 回执失败或多块中坏一块但数据文件读到——数据已经流
  /// 过去了，失败只留在传输级计数 / 错误里）。完全没读到数据时的读取 /
  /// 解密失败仍按设备保留。
  final Map<String, SyncIssue> failedIssues;

  /// 本轮是否接触到了远端（WebDAV 目录可读、局域网有对端可达）。
  ///
  /// 零快照也算接触：目录可读说明远端可达，用于把「远端可达但还没有数据」
  /// 与「所有对端都不可达」分开（后者才是整轮失败）。
  final bool contacted;

  /// 最近一次失败的原因（无失败为 null）；技术细节在 [SyncIssue.detail]。
  final SyncIssue? error;

  static const SyncPullResult none = SyncPullResult();
}

/// 一次推送的结果（按对端计）。
///
/// [succeededIds] / [failedIds] 只在传输能归属到具体对端时给出（局域网）；
/// WebDAV 只有「自身上传成功/失败」一个目标，用计数表达即可。
class SyncPushResult {
  const SyncPushResult({
    this.succeededPeers = 0,
    this.failedPeers = 0,
    this.succeededIds = const [],
    this.failedIds = const [],
    this.bytesOut = 0,
    this.error,
  });

  final int succeededPeers;
  final int failedPeers;
  final List<String> succeededIds;
  final List<String> failedIds;
  final int bytesOut;

  /// 最近一次失败的原因（无失败为 null）；技术细节在 [SyncIssue.detail]。
  final SyncIssue? error;

  static const SyncPushResult none = SyncPushResult();
}

/// 同步传输端口：把「本地快照 ↔ 远端快照」的搬运与加密解耦。
///
/// 实现（局域网直连 / WebDAV）负责发现对端、加解密与网络错误容忍；
/// 引擎只消费 [pull] 的结果并调用 [push] 发布合并结果。
/// 任何单点失败都不应抛出（返回部分结果并如实计数），错误经报告与日志呈现。
abstract interface class SyncTransport {
  /// 传输标识（持久化配置键）：`lan` / `webdav`。
  String get kind;

  /// 启动常驻资源（局域网为 UDP/HTTP 监听；WebDAV 无操作）。
  Future<void> start();

  /// 停止常驻资源。
  Future<void> stop();

  bool get isRunning;

  /// 本机发现端口（分族）：`v4` / `v6` 为对应地址族实际绑定的 UDP 探测
  /// 端口，0 = 该族没有发现通道 / 未运行。
  ///
  /// 为什么分族：v4 广播与 v6 组播两族可独立降级（端口被系统保留 / 被占用
  /// 时各自改绑系统分配端口），两族端口可能不同——对端（或手动地址）必须按
  /// 自己要用哪一族取对应端口，拿另一族的端口会打不通。WebDAV 无发现通道，
  /// 恒为 `(v4: 0, v6: 0)`。引擎 / UI 层按「局域网」映射为
  /// `lanDiscoveryPorts`（引擎可挂多个传输，带 `lan` 前缀限定）。
  ({int v4, int v6}) get discoveryPorts => (v4: 0, v6: 0);

  /// 对端是否按需拉取**实时**全量快照（局域网直连 = true：端点随时给出当前
  /// 视图，没有发布延迟；WebDAV = false：快照文件是异步读取的）。
  ///
  /// 引擎据此决定日志裁剪的下限：只有「需要发布快照文件」的传输才把已发布
  /// 覆盖计入（否则落后 / 新加入的对端无法 bootstrap）。
  bool get servesLiveSnapshot;

  /// 传输当前不可用的原因码（null = 可用）。
  ///
  /// 机器可读码（[SyncUnavailableReason] 的 `not_configured` /
  /// `start_failed` / `permission_denied`），由 UI 映射文案；
  /// 行为上不改变任何逻辑，只用于把「开关开着但根本没在工作」呈现出来。
  String? get unavailableReason;

  /// 不可用原因的技术细节（排查用；null = 无细节）。
  ///
  /// 原始异常 / 错误串只进 Logger 与日志子页的失败详情，UI 展示的是原因码
  /// 映射文案。
  String? get unavailableDetail;

  /// 拉取当前可获得的远端载荷（增量窗口或 bootstrap 全量快照；
  /// 解密失败的对端跳过并计数）。
  Future<SyncPullResult> pull([SyncPullRequest request]);

  /// 推送本地载荷（增量窗口 / 需要发布的全量快照；对端后续轮次拉取可见）。
  ///
  /// [window] 与同一轮的 [pull] 使用同一个 [SyncRoundWindow]：需要按
  /// 「本轮观测」判定预期对端的传输（局域网）据此计数，不能依赖
  /// 「本轮一定刚跑过 pull」的隐式状态。缺省 = 传输取当前时间，单独调用
  /// push（测试 / 手动补偿）仍有确定语义。
  Future<SyncPushResult> push(
    SyncEnvelope envelope, {
    SyncRoundWindow? window,
  });

  /// 显式清理某个对端的远端文件（用户动作；**不做自动删除**）。
  ///
  /// 返回 false = 该传输没有可清理的远端文件（局域网直连无远端存储）或删除
  /// 失败。局域网实现恒返回 false。
  Future<bool> deleteRemote(String deviceId);

  /// 对端主动送来的快照（局域网 POST / WebDAV 无此通道时为广播流）。
  Stream<SyncEnvelope> get incoming;
}

/// 发现事件能力（局域网传输实现）：认证通过的对端公告 / 应答。
///
/// 窄接口而不是往 [SyncTransport] 加方法：WebDAV 没有发现概念，引擎按
/// 「实现了这个接口才订阅」接线，避免给所有传输伪造空流。
abstract interface class SyncSightingSource {
  Stream<LanPeerSighting> get sightings;
}

/// 局域网生命周期能力（回前台 / 退后台 / 换网 / 本地变更公告）。
///
/// 与 [SyncSightingSource] 一样是能力接口：控制面只在传输实现了它时才调用，
/// WebDAV 传输不受影响。
abstract interface class SyncLanLifecycle {
  Future<void> onAppResumed();

  void onAppHidden();

  Future<void> onNetworkChanged();

  /// 本地变更但本轮推送零对端时的单次定向公告（只单播，不广播）。
  Future<void> announceLocalChange();
}

/// 传输不可用原因码（[SyncTransport.unavailableReason]）。
///
/// 与 [SyncIssueCode] 同名常量同值：传输状态与一轮失败共用一套文案映射。
abstract final class SyncUnavailableReason {
  /// 已启用但缺少必要配置（如 WebDAV 未填服务器地址）。
  static const String notConfigured = SyncIssueCode.notConfigured;

  /// 启动失败（端口占用、权限不足等）。
  static const String startFailed = SyncIssueCode.startFailed;

  /// 局域网访问权限未授予（Android 17 起局域网默认阻断；手动地址也无效）。
  static const String permissionDenied = SyncIssueCode.permissionDenied;
}

/// 传输标识（持久化配置键 / 报告 kind / UI 开关共用）。
abstract final class SyncTransportKind {
  static const String lan = 'lan';
  static const String webdav = 'webdav';
}
