import '../models/device_sync.dart';

/// 一次拉取的结果。
///
/// 失败按宽容处理（不抛异常）：单个对端的网络 / 解密失败只计入 [failedPeers]，
/// 其余对端的结果照常返回。[peersSeen] 是本轮实际探测到 / 列出的对端数——
/// 「一个对端都没发现」与「没有变化」必须能被上层区分开。
class SyncPullResult {
  const SyncPullResult({
    this.envelopes = const [],
    this.peersSeen = 0,
    this.failedPeers = 0,
    this.bytesIn = 0,
    this.error,
  });

  final List<SyncEnvelope> envelopes;

  /// 探测到 / 列出的对端数（含未变而跳过、解密失败的）。
  final int peersSeen;

  /// 拉取或解密失败的对端数。
  final int failedPeers;

  final int bytesIn;

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

  /// 传输当前不可用的原因码（null = 可用）。
  ///
  /// 机器可读码（[SyncUnavailableReason] 的 `not_configured` /
  /// `start_failed` / `permission_denied`），由 UI 映射文案；
  /// 行为上不改变任何逻辑，只用于把「开关开着但根本没在工作」呈现出来。
  String? get unavailableReason;

  /// 不可用原因的技术细节（诊断用；null = 无细节）。
  ///
  /// 原始异常 / 错误串只进日志与诊断导出，UI 展示的是原因码映射文案。
  String? get unavailableDetail;

  /// 拉取当前可获得的远端快照（解密失败的对端跳过并计数）。
  Future<SyncPullResult> pull();

  /// 推送本地快照（对端后续轮次拉取可见）。
  Future<SyncPushResult> push(SyncEnvelope envelope);

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
