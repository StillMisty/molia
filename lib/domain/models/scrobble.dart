/// 听歌同步（scrobble）的领域模型：事件、投递结果与账号状态。
///
/// 纯 Dart：不含 HTTP、存储或 UI 细节，协议适配器（`services/scrobble/`）
/// 与组合根共用这一份口径。
library;

/// 支持的两个外部服务。
enum ScrobbleTarget { listenBrainz, lastFm }

/// 事件类型：正在播放（一次性提示）与已播完（计入收听历史）。
enum ScrobbleEventKind { nowPlaying, scrobble }

/// 发送用的曲目元数据。
///
/// 只保留协议需要的字段：本地文件路径、音源 payload、封面地址都不进入
/// 这里，避免把「发送面」意外扩大。
class ScrobbleTrack {
  const ScrobbleTrack({
    required this.title,
    required this.artist,
    this.album,
    required this.duration,
    this.trackNumber,
  });

  final String title;
  final String artist;
  final String? album;
  final Duration duration;

  /// 曲目序号（本地标签有值时才有；协议层可省略）。
  final int? trackNumber;

  @override
  bool operator ==(Object other) =>
      other is ScrobbleTrack &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.duration == duration &&
      other.trackNumber == trackNumber;

  @override
  int get hashCode => Object.hash(title, artist, album, duration, trackNumber);

  @override
  String toString() => 'ScrobbleTrack($title, $artist)';
}

/// 一次播放（会话）的收听事实。
///
/// [startedAt] 是本次播放真正开始的时刻：离线排队后补发时，历史时间仍然
/// 正确，而不是「补发那一刻」。
class ScrobbleListen {
  const ScrobbleListen({required this.track, required this.startedAt});

  final ScrobbleTrack track;
  final DateTime startedAt;

  @override
  bool operator ==(Object other) =>
      other is ScrobbleListen &&
      other.track == track &&
      other.startedAt == startedAt;

  @override
  int get hashCode => Object.hash(track, startedAt);
}

/// 待发送 / 已发送事件的身份。
class ScrobbleEvent {
  const ScrobbleEvent({
    required this.id,
    required this.target,
    required this.kind,
    required this.listen,
    required this.createdAt,
  });

  /// 本地稳定 id（outbox 去重与持久化用）。
  final String id;
  final ScrobbleTarget target;
  final ScrobbleEventKind kind;
  final ScrobbleListen listen;

  /// 入队时间（与 [ScrobbleListen.startedAt] 区分：补发时两者不同）。
  final DateTime createdAt;

  ScrobbleEvent copyWith({
    String? id,
    ScrobbleTarget? target,
    ScrobbleEventKind? kind,
    ScrobbleListen? listen,
    DateTime? createdAt,
  }) => ScrobbleEvent(
    id: id ?? this.id,
    target: target ?? this.target,
    kind: kind ?? this.kind,
    listen: listen ?? this.listen,
    createdAt: createdAt ?? this.createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is ScrobbleEvent &&
      other.id == id &&
      other.target == target &&
      other.kind == kind &&
      other.listen == listen &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, target, kind, listen, createdAt);
}

/// 一次请求的结论（适配器只描述事实，不决定重试策略）。
enum ScrobbleDeliveryOutcome {
  /// 服务明确接受。
  success,

  /// 网络 / 5xx / 429：可以稍后重试。
  retryable,

  /// 401 / 403 / 口令无效：停止发送，等用户重新授权。
  unauthorized,

  /// 请求本身不可能成功（参数错误、服务未配置）：不要无限重试。
  permanent,
}

/// 适配器返回的投递结果。
class ScrobbleDelivery {
  const ScrobbleDelivery._(this.outcome, {this.retryAfter, this.reason});

  const ScrobbleDelivery.success() : this._(ScrobbleDeliveryOutcome.success);

  const ScrobbleDelivery.retryable({Duration? retryAfter, String? reason})
    : this._(
        ScrobbleDeliveryOutcome.retryable,
        retryAfter: retryAfter,
        reason: reason,
      );

  const ScrobbleDelivery.unauthorized({String? reason})
    : this._(ScrobbleDeliveryOutcome.unauthorized, reason: reason);

  const ScrobbleDelivery.permanent({String? reason})
    : this._(ScrobbleDeliveryOutcome.permanent, reason: reason);

  final ScrobbleDeliveryOutcome outcome;

  /// 服务给出的等待时间（429 的 Retry-After）；没有则按退避策略。
  final Duration? retryAfter;

  /// 面向日志的短原因。**不得包含令牌、签名或请求正文**。
  final String? reason;

  bool get isSuccess => outcome == ScrobbleDeliveryOutcome.success;
}

/// 一个服务的连接状态（设置页与发送调度共用）。
enum ScrobbleTargetStatus {
  /// 未连接 / 未启用。
  disconnected,

  /// 已连接，正在发送或空闲。
  connected,

  /// 口令失效，需要重新授权。
  needsAuthorization,

  /// 最近一次发送失败，正在退避重试。
  retrying,

  /// 不可恢复的发送失败（例如服务未配置）。
  error,
}

/// ListenBrainz 口令验证结果。
class ScrobbleCredentialCheck {
  const ScrobbleCredentialCheck.valid(this.accountName)
    : isValid = true,
      reachable = true;

  const ScrobbleCredentialCheck.invalid()
    : isValid = false,
      reachable = true,
      accountName = null;

  /// 网络失败：不能据此判定口令错误。
  const ScrobbleCredentialCheck.unreachable()
    : isValid = false,
      reachable = false,
      accountName = null;

  final bool isValid;
  final bool reachable;
  final String? accountName;
}

/// Last.fm 浏览器授权状态。
enum LastFmAuthStage {
  /// 未开始。
  idle,

  /// 已拿到请求令牌，等待用户在浏览器授权。
  awaitingUser,

  /// 正在换取会话密钥。
  exchanging,

  /// 已连接。
  connected,

  /// 用户取消 / 令牌过期。
  cancelled,

  /// 交换失败。
  failed,
}
