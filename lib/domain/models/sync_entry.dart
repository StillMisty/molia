/// 同步设置页直接展示的纯领域值：WebDAV 配置与轮次日志条目。
///
/// 两类值由 data 层持久化，但 UI（设置页 / 日志子页）与 provider 的只读投影
/// 需要构造和读取它们；放在领域层避免 pages/widgets 反向依赖 `lib/data/**`。
library;

import 'device_sync.dart';

/// WebDAV 传输配置（密码单独走凭据库，不在此结构内）。
class WebDavConfig {
  final String baseUrl;
  final String username;

  /// 远端目录名（相对 baseUrl，默认 `molia-sync`）。
  final String remoteDir;

  const WebDavConfig({
    this.baseUrl = '',
    this.username = '',
    this.remoteDir = 'molia-sync',
  });

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  WebDavConfig copyWith({
    String? baseUrl,
    String? username,
    String? remoteDir,
  }) => WebDavConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    username: username ?? this.username,
    remoteDir: remoteDir ?? this.remoteDir,
  );

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'username': username,
    'remoteDir': remoteDir,
  };

  static WebDavConfig fromJson(Object? raw) {
    if (raw is! Map) return const WebDavConfig();
    return WebDavConfig(
      baseUrl: raw['baseUrl'] is String ? raw['baseUrl'] as String : '',
      username: raw['username'] is String ? raw['username'] as String : '',
      remoteDir:
          raw['remoteDir'] is String &&
              (raw['remoteDir'] as String).trim().isNotEmpty
          ? (raw['remoteDir'] as String).trim()
          : 'molia-sync',
    );
  }
}

/// 同步日志条目（设置页日志子页展示；不含口令/密钥内容）。
///
/// 语义是**本轮变更量**：`applied` 是本轮真正落地的记录数，与库大小无关。
class SyncLogEntry {
  const SyncLogEntry({
    required this.at,
    required this.trigger,
    required this.outcome,
    this.durationMs = 0,
    this.applied = 0,
    this.peersSeen = 0,
    this.failed = 0,
    this.bytesIn = 0,
    this.bytesOut = 0,
    this.transports = const [],
    this.error,
  });

  final int at;

  /// 触发原因（用户能看出「为什么现在同步」）。
  final SyncTrigger trigger;

  final SyncOutcome outcome;
  final int durationMs;

  /// 本轮落地的记录数（变更量）。
  final int applied;

  /// 本轮接触到的对端数（0 = 未发现对端）。
  final int peersSeen;

  /// 失败计数（拉取 + 推送）。
  final int failed;

  final int bytesIn;
  final int bytesOut;

  /// 本轮启用的传输标识。
  final List<String> transports;

  /// 失败原因（类型化；技术细节在 [SyncIssue.detail]，UI 不展示原文）。
  final SyncIssue? error;

  Map<String, dynamic> toJson() => {
    'at': at,
    'trigger': trigger.name,
    'outcome': outcome.name,
    if (durationMs > 0) 'durationMs': durationMs,
    if (applied > 0) 'applied': applied,
    if (peersSeen > 0) 'peersSeen': peersSeen,
    if (failed > 0) 'failed': failed,
    if (bytesIn > 0) 'bytesIn': bytesIn,
    if (bytesOut > 0) 'bytesOut': bytesOut,
    if (transports.isNotEmpty) 'transports': transports,
    if (error != null) 'error': error!.toJson(),
  };

  static SyncLogEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = raw['at'];
    if (at is! num) return null;
    return SyncLogEntry(
      at: at.toInt(),
      trigger: SyncTrigger.parse(raw['trigger'] as String?),
      outcome: SyncOutcome.parse(raw['outcome'] as String?),
      durationMs: (raw['durationMs'] as num?)?.toInt() ?? 0,
      applied: (raw['applied'] as num?)?.toInt() ?? 0,
      peersSeen: (raw['peersSeen'] as num?)?.toInt() ?? 0,
      failed: (raw['failed'] as num?)?.toInt() ?? 0,
      bytesIn: (raw['bytesIn'] as num?)?.toInt() ?? 0,
      bytesOut: (raw['bytesOut'] as num?)?.toInt() ?? 0,
      transports:
          (raw['transports'] as List?)?.whereType<String>().toList() ??
          const [],
      error: SyncIssue.fromJson(raw['error']),
    );
  }
}
