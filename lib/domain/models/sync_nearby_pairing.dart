/// 局域网附近设备与一键配对的纯领域模型。
///
/// 与旧的 `SyncPairingCode`（二维码 / 粘贴文本）无关：新路径只交换**设备
/// 候选**与**配对请求状态**，口令从不进入可展示文本。所有 `toString` 都
/// 只含设备 / 请求标识，避免把口令或密封载荷带进日志与错误详情。
library;

/// 配对意图。
///
/// - [join]：发起方没有同步组，希望接收方接受后把接收方口令交给它；
/// - [invite]：发起方已有同步组，接受后由发起方把口令交给接收方。
///
/// 实际方向由双方是否已有同步组决定，请求里的意图只用于一致性校验。
enum SyncPairingIntent {
  join,
  invite;

  static SyncPairingIntent? tryParse(String? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// 配对的线上 / UI 状态。
enum SyncPairingStatus {
  pending,
  accepted,
  rejected,
  expired,
  conflict,
  sameGroup,
  unavailable,
  busy,

  /// 本机主动取消（只存在于发起方的本地状态，线上不会出现）。
  cancelled;

  static SyncPairingStatus parse(String? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return SyncPairingStatus.unavailable;
  }
}

/// 一次 `requestPairing` 的最终结局（UI 按此映射文案与动作）。
enum SyncPairingOutcome {
  accepted,
  rejected,
  expired,
  conflict,
  sameGroup,
  unreachable,
  busy,
  unsupported,
  unavailable,
  cancelled;

  static SyncPairingOutcome fromStatus(SyncPairingStatus status) {
    switch (status) {
      case SyncPairingStatus.accepted:
        return SyncPairingOutcome.accepted;
      case SyncPairingStatus.rejected:
        return SyncPairingOutcome.rejected;
      case SyncPairingStatus.expired:
        return SyncPairingOutcome.expired;
      case SyncPairingStatus.conflict:
        return SyncPairingOutcome.conflict;
      case SyncPairingStatus.sameGroup:
        return SyncPairingOutcome.sameGroup;
      case SyncPairingStatus.busy:
        return SyncPairingOutcome.busy;
      case SyncPairingStatus.unavailable:
        return SyncPairingOutcome.unavailable;
      case SyncPairingStatus.cancelled:
        return SyncPairingOutcome.cancelled;
      case SyncPairingStatus.pending:
        return SyncPairingOutcome.unavailable;
    }
  }
}

/// 局域网附近的一台 Molia 设备（`MSP/1` 应答的当前观测）。
///
/// [host] 是 UDP 来源地址，[addresses] 是对端自报的候选地址；两者都只用于
/// 配对 HTTP 请求，不写名册 / presence。
class SyncNearbyDevice {
  const SyncNearbyDevice({
    required this.deviceId,
    required this.name,
    required this.host,
    required this.httpPort,
    this.probePort = 0,
    this.addresses = const [],
    this.hasGroup = false,
    this.bootId = '',
    required this.lastSeenAt,
  });

  final String deviceId;
  final String name;

  /// UDP 来源地址（真实可达的观测值）。
  final String host;

  /// 对端 HTTP 端点端口（0 = 对端尚未绑定，当前不可配对）。
  final int httpPort;

  /// 对端 UDP 探测端口（保存端点后用于发现 / 兜底）。
  final int probePort;

  /// 对端自报的地址候选（同一设备的双栈 / 多网卡地址）。
  final List<String> addresses;

  /// 对端是否已有同步组（只是提示；真正的同组 / 冲突由 group proof 判定）。
  final bool hasGroup;

  /// 对端进程启动 id（对端重启后即使地址不变也视为新观测）。
  final String bootId;

  /// 最近一次收到应答的时间（毫秒时间戳）。
  final int lastSeenAt;

  @override
  String toString() => 'SyncNearbyDevice($deviceId, $host:$httpPort)';
}

/// 一条待用户确认的配对请求（接收方 UI 展示）。
class SyncPairingRequest {
  const SyncPairingRequest({
    required this.requestId,
    required this.peerDeviceId,
    required this.peerName,
    required this.intent,
    required this.code,
    required this.expiresAt,
    this.peerHasGroup = false,
  });

  final String requestId;
  final String peerDeviceId;
  final String peerName;
  final SyncPairingIntent intent;

  /// 6 位确认码（双方由同一份握手材料派生，用户核对后决定接受 / 拒绝）。
  final String code;

  /// 过期时间（毫秒时间戳；60 秒）。
  final int expiresAt;

  /// 发起方是否已有同步组（展示提示用，不参与信任判定）。
  final bool peerHasGroup;

  @override
  String toString() =>
      'SyncPairingRequest($requestId, $peerDeviceId, ${intent.name})';
}

/// 发起方的一次配对尝试（UI 展示确认码与等待状态）。
class SyncPairingAttempt {
  const SyncPairingAttempt({
    required this.requestId,
    required this.peerDeviceId,
    required this.peerName,
    required this.intent,
    required this.code,
    required this.status,
    required this.expiresAt,
  });

  final String requestId;
  final String peerDeviceId;
  final String peerName;
  final SyncPairingIntent intent;
  final String code;
  final SyncPairingStatus status;
  final int expiresAt;

  SyncPairingAttempt copyWith({SyncPairingStatus? status}) =>
      SyncPairingAttempt(
        requestId: requestId,
        peerDeviceId: peerDeviceId,
        peerName: peerName,
        intent: intent,
        code: code,
        status: status ?? this.status,
        expiresAt: expiresAt,
      );

  @override
  String toString() =>
      'SyncPairingAttempt($requestId, ${status.name}, ${intent.name})';
}

/// `requestPairing` 的结果：只含类型化结局与可展示状态，不含任何密钥材料。
class SyncPairingResult {
  const SyncPairingResult({required this.outcome, this.attempt});

  final SyncPairingOutcome outcome;
  final SyncPairingAttempt? attempt;

  bool get isSuccess =>
      outcome == SyncPairingOutcome.accepted ||
      outcome == SyncPairingOutcome.sameGroup;

  @override
  String toString() => 'SyncPairingResult(${outcome.name})';
}
