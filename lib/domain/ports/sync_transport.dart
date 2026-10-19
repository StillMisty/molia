import '../models/device_sync.dart';

/// 一次拉取的请求参数（增量协议：本机游标 + 需要全量兜底的对端）。
///
/// 传输实现按 [cursors] 请求「游标之后的增量窗口」（局域网带查询参数；
/// WebDAV 本地过滤文件里的窗口），并在对端日志窗口已不含本机游标时改取
/// bootstrap 全量快照；[fullPeers] 是引擎显式要求全量的对端（anti-entropy
/// 发现指纹不一致，或上一轮发现窗口缺口）。
class SyncPullRequest {
  const SyncPullRequest({
    this.cursors = const {},
    this.fullPeers = const {},
  });

  /// 本机已消费各对端 journal 的位置（对端 id → seq）。
  final Map<String, int> cursors;

  /// 强制走全量快照的对端 id。
  final Set<String> fullPeers;

  /// 未记录过的对端：尚未消费任何条目。
  static const int noCursor = -1;

  static const SyncPullRequest none = SyncPullRequest();

  int cursorFor(String deviceId) => cursors[deviceId] ?? noCursor;
}

/// 一次拉取的结果。
///
/// 失败按宽容处理（不抛异常）：单个对端的网络 / 解密失败只计入 [failedPeers]，
/// 其余对端的结果照常返回。[peersSeen] 是本轮实际探测到 / 列出的对端数——
/// 「一个对端都没发现」与「没有变化」必须能被上层区分开。
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

  /// 本轮**接触过**的对端 id（含未变跳过、读取失败者；不含幽灵文件）。
  ///
  /// 名册的「最近接触」据此更新：在线但长期没有内容变化的对端不该被误标
  /// 失联。
  final List<String> seenIds;

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
  /// 时各自改绑系统分配端口），两族端口可能不同——对端（或配对码）必须按
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
  Future<SyncPushResult> push(SyncEnvelope envelope);

  /// 显式清理某个对端的远端文件（用户动作；**不做自动删除**）。
  ///
  /// 返回 false = 该传输没有可清理的远端文件（局域网直连无远端存储）或删除
  /// 失败。局域网实现恒返回 false。
  Future<bool> deleteRemote(String deviceId);

  /// 对端主动送来的快照（局域网 POST / WebDAV 无此通道时为广播流）。
  Stream<SyncEnvelope> get incoming;
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
