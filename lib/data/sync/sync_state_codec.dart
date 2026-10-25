/// 同步运行状态（`sync_state_v2`）的持久化形状与编解码。
///
/// 为什么单独一层：`SyncStateStore` 的职责是内存状态与写入时机（脏标记 /
/// 单一提交 / 身份备份），JSON 只是它的落盘细节。把「字段 ↔ JSON」收进无
/// 状态模块后：
/// - 键名、条件字段、容错默认值与保留上限只有一处实现，存储层不再同时维护
///   内存状态和格式两份逻辑；
/// - 测试可以直接对形状做往返断言，不必构造 SharedPreferences 与安全存储；
/// - 格式变更集中出现在本文件，评审能一眼看到对旧状态的兼容影响。
///
/// 解码是**宽容**的：字段类型不符按默认值、非法条目丢弃、超限截断，只有载荷
/// 根本不是 JSON 对象时才返回 null（对应存储层「损坏状态按默认处理」的回退
/// 路径）；旧键不读、不迁移（见 ADR-0003 的硬断代）。
library;

import '../../domain/models/device_sync.dart';
import '../../utils/peer_address.dart';
import 'sync_activity.dart';
import 'sync_book.dart' show syncPeerLimit;
import 'sync_stamp.dart';

/// WebDAV 传输配置（密码单独走安全存储，不在此结构内）。
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

  WebDavConfig copyWith(
          {String? baseUrl, String? username, String? remoteDir}) =>
      WebDavConfig(
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
      remoteDir: raw['remoteDir'] is String &&
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
      transports: (raw['transports'] as List?)?.whereType<String>().toList() ??
          const [],
      error: SyncIssue.fromJson(raw['error']),
    );
  }
}

/// `sync_state_v2` 的内存快照：JSON 能表达的**全部**字段。
///
/// 构造时复制集合，实例创建后不再变化：写入方可以放心把快照交给异步编码，
/// 之后的用户命令不会改到正在落盘的内容。
class SyncPersistedState {
  SyncPersistedState({
    this.deviceId = '',
    this.deviceName = '',
    Map<SyncCategory, bool>? categories,
    Set<String> transports = const {},
    this.webdav = const WebDavConfig(),
    this.cellularPolicy = SyncCellularPolicy.auto,
    List<ManualPeer> manualPeers = const [],
    Set<String> notifiedPeers = const {},
    this.lanHttpPort = 0,
    this.stampBaseline = SyncVersion.zero,
    Map<String, SyncStamp> settingStamps = const {},
    Map<String, SyncStamp> scriptTombstones = const {},
    Map<String, SyncStamp> scriptStamps = const {},
    List<String> knownScriptIds = const [],
    this.activeScriptStamp,
    this.sessionStamp,
    Map<String, SyncStamp> coverStamps = const {},
    Map<String, SyncStamp> coverTombstones = const {},
    this.lastSyncAt = 0,
    Map<String, int> transportLastSuccess = const {},
    Map<String, int> snapshotPushSeq = const {},
    List<SyncLogEntry> log = const [],
    List<SyncActivityEntry> activity = const [],
    List<SyncPeerState> peers = const [],
    List<LanPeerEndpoint> lanEndpoints = const [],
  })  : categories = Map.unmodifiable(categories ??
            {
              for (final category in SyncCategory.values)
                category: category.defaultEnabled,
            }),
        transports = Set.unmodifiable(transports),
        manualPeers = List.unmodifiable(manualPeers),
        notifiedPeers = Set.unmodifiable(notifiedPeers),
        settingStamps = Map.unmodifiable(settingStamps),
        scriptTombstones = Map.unmodifiable(scriptTombstones),
        scriptStamps = Map.unmodifiable(scriptStamps),
        coverStamps = Map.unmodifiable(coverStamps),
        coverTombstones = Map.unmodifiable(coverTombstones),
        knownScriptIds = List.unmodifiable(knownScriptIds),
        transportLastSuccess = Map.unmodifiable(transportLastSuccess),
        snapshotPushSeq = Map.unmodifiable(snapshotPushSeq),
        log = List.unmodifiable(log),
        activity = List.unmodifiable(activity),
        peers = List.unmodifiable(peers),
        lanEndpoints = List.unmodifiable(lanEndpoints);

  /// 设备身份的状态内副本（独立 prefs 键 / 安全存储才是损坏时的恢复来源）。
  final String deviceId;

  final String deviceName;

  /// 类别开关（缺失 = 全开，与全新安装一致）。
  final Map<SyncCategory, bool> categories;

  /// 启用的传输 kind（空 = 同步关闭；传输开关就是总闸）。
  final Set<String> transports;

  final WebDavConfig webdav;
  final SyncCellularPolicy cellularPolicy;

  /// 手动地址簿（顺序即探测与展示的优先序）。
  final List<ManualPeer> manualPeers;

  /// 已提示过「首次连通」的设备 id（一次性 UI 提示）。
  final Set<String> notifiedPeers;

  /// 本机局域网快照端点端口（0 = 尚未绑定过）。
  final int lanHttpPort;

  /// 版本戳发号器基线（JSON 键 `stampSeq`）；重启后不倒退。
  final SyncVersion stampBaseline;

  /// 设置键 → 登记哈希 + 版本。
  final Map<String, SyncStamp> settingStamps;

  /// 脚本 id → 删除墓碑。
  final Map<String, SyncStamp> scriptTombstones;

  /// 脚本 id → 内容哈希 + 版本（本地变化检测）。
  final Map<String, SyncStamp> scriptStamps;

  /// 上一轮收集到的脚本 id（本地删除检测的基线）。
  final List<String> knownScriptIds;

  /// 激活脚本指针的登记。
  final SyncStamp? activeScriptStamp;

  /// 上次播放会话的登记。
  final SyncStamp? sessionStamp;

  /// 自定义封面键 → 内容哈希 + 版本（本地变化检测）。
  final Map<String, SyncStamp> coverStamps;

  /// 自定义封面键 → 删除墓碑。
  final Map<String, SyncStamp> coverTombstones;

  final int lastSyncAt;

  /// 每传输最近一次成功接触对端的轮次时间。
  final Map<String, int> transportLastSuccess;

  /// 各传输最近成功发布的全量快照覆盖位置（kind → seq）。
  final Map<String, int> snapshotPushSeq;

  /// 展示日志（新在前；上限 [SyncStateCodec.logLimit]）。
  final List<SyncLogEntry> log;

  /// 近 24 小时活动记录（新在前；上限 [SyncStateCodec.activityLimit]）。
  final List<SyncActivityEntry> activity;

  /// 设备名册（按最近接触时间倒序；本机不在其中）。
  final List<SyncPeerState> peers;

  /// 已验证的局域网端点（[SyncStateCodec.lanEndpointLimit] 上限）。
  final List<LanPeerEndpoint> lanEndpoints;
}

/// `sync_state_v2` 的编解码：唯一维护 JSON 键名、条件字段与容错规则的地方。
abstract final class SyncStateCodec {
  /// 日志保留条数（设置页只展示最近几条；解码与运行时淘汰共用）。
  static const int logLimit = 20;

  /// 活动记录保留条数（近 24 小时汇总用；展示日志不足以支撑窗口）。
  static const int activityLimit = 240;

  /// 名册保留设备数（与轮次名册共用同一上限）。
  static const int peerLimit = syncPeerLimit;

  /// 已验证局域网端点保留条数（MAC + HTTP 解密成功才写入）。
  static const int lanEndpointLimit = 32;

  /// 编码为 `sync_state_v2` 的 JSON 对象。
  ///
  /// 键名、写入顺序与条件字段（非空才写）是持久化契约：改这里等于改格式，
  /// 需要同时确认解码侧的默认值。
  static Map<String, dynamic> encode(SyncPersistedState state) => {
        'v': 2,
        'deviceId': state.deviceId,
        'deviceName': state.deviceName,
        'categories': {
          for (final entry in state.categories.entries)
            entry.key.name: entry.value,
        },
        'transports': state.transports.toList(),
        'webdav': state.webdav.toJson(),
        'cellularPolicy': state.cellularPolicy.name,
        if (state.manualPeers.isNotEmpty)
          'manualPeers': [for (final peer in state.manualPeers) peer.toJson()],
        if (state.notifiedPeers.isNotEmpty)
          'notifiedPeers': state.notifiedPeers.toList(),
        if (state.lanHttpPort > 0) 'lanHttpPort': state.lanHttpPort,
        // 设备身份同时写在独立键 deviceIdKey 里；这里保留一份让状态 JSON
        // 自描述（读取时以独立键 / 状态里的非空值为准）。
        'stampSeq': state.stampBaseline.toJson(),
        'settings': {
          for (final entry in state.settingStamps.entries)
            entry.key: entry.value.toJson(),
        },
        'scriptTombstones': {
          for (final entry in state.scriptTombstones.entries)
            entry.key: entry.value.toJson(),
        },
        'scriptStamps': {
          for (final entry in state.scriptStamps.entries)
            entry.key: entry.value.toJson(),
        },
        'knownScripts': state.knownScriptIds,
        if (state.activeScriptStamp != null)
          'activeScript': state.activeScriptStamp!.toJson(),
        if (state.sessionStamp != null)
          'sessionStamp': state.sessionStamp!.toJson(),
        'coverStamps': {
          for (final entry in state.coverStamps.entries)
            entry.key: entry.value.toJson(),
        },
        'coverTombstones': {
          for (final entry in state.coverTombstones.entries)
            entry.key: entry.value.toJson(),
        },
        'lastSyncAt': state.lastSyncAt,
        if (state.transportLastSuccess.isNotEmpty)
          'transportLastSuccess': state.transportLastSuccess,
        if (state.snapshotPushSeq.isNotEmpty)
          'snapshotPush': state.snapshotPushSeq,
        'log': [for (final entry in state.log) entry.toJson()],
        'activity': [for (final entry in state.activity) entry.toJson()],
        'peers': [for (final peer in state.peers) peer.toJson()],
        if (state.lanEndpoints.isNotEmpty)
          'lanEndpoints': [
            for (final endpoint in state.lanEndpoints) endpoint.toJson(),
          ],
      };

  /// 解码 `sync_state_v2`；载荷根本不是 JSON 对象时返回 null。
  ///
  /// 字段级容错与存储层原来的解析规则一致：类型不符按默认值、非法条目丢弃、
  /// 超限截断。不会抛异常——调用方只按「有没有可用状态」分支（解析失败 /
  /// 损坏时仍走设备身份恢复，不能把身份一起重生成）。
  static SyncPersistedState? decode(Object? raw) {
    if (raw is! Map) return null;

    final categories = <SyncCategory, bool>{
      for (final category in SyncCategory.values)
        category: category.defaultEnabled,
    };
    final storedCategories = raw['categories'];
    if (storedCategories is Map) {
      for (final category in SyncCategory.values) {
        final value = storedCategories[category.name];
        if (value is bool) categories[category] = value;
      }
    }

    final transports = <String>{};
    final storedTransports = raw['transports'];
    if (storedTransports is List) {
      transports.addAll(storedTransports.whereType<String>());
    }

    final manualPeers = <ManualPeer>[];
    final storedManualPeers = raw['manualPeers'];
    if (storedManualPeers is List) {
      for (final item in storedManualPeers) {
        final peer = _tryParse(ManualPeer.fromJson, item);
        if (peer != null) manualPeers.add(peer);
      }
    }

    final notifiedPeers = <String>{};
    final storedNotifiedPeers = raw['notifiedPeers'];
    if (storedNotifiedPeers is List) {
      notifiedPeers.addAll(storedNotifiedPeers.whereType<String>());
    }

    final knownScriptIds = <String>[];
    final storedKnownScripts = raw['knownScripts'];
    if (storedKnownScripts is List) {
      knownScriptIds.addAll(storedKnownScripts.whereType<String>());
    }

    // 名册按 deviceId 去重（后写覆盖前写，位置保持首次插入序），与运行时
    // 的 Map 语义一致；上限只看有效条目。
    final peers = <String, SyncPeerState>{};
    final storedPeers = raw['peers'];
    if (storedPeers is List) {
      for (final item in storedPeers) {
        final peer = _tryParse(SyncPeerState.fromJson, item);
        if (peer != null && peers.length < peerLimit) {
          peers[peer.deviceId] = peer;
        }
      }
    }

    final lanEndpoints = <String, LanPeerEndpoint>{};
    final storedLanEndpoints = raw['lanEndpoints'];
    if (storedLanEndpoints is List) {
      for (final item in storedLanEndpoints) {
        final endpoint = _tryParse(LanPeerEndpoint.fromJson, item);
        // 非法条目（不可路由地址 / 越界端口 / 空 id）直接丢弃，不拖垮整份状态。
        if (endpoint != null && isValidLanEndpoint(endpoint)) {
          lanEndpoints[endpoint.deviceId] = endpoint;
        }
        if (lanEndpoints.length >= lanEndpointLimit) break;
      }
    }

    return SyncPersistedState(
      deviceId: raw['deviceId'] is String ? raw['deviceId'] as String : '',
      deviceName:
          raw['deviceName'] is String ? raw['deviceName'] as String : '',
      categories: categories,
      transports: transports,
      webdav: WebDavConfig.fromJson(raw['webdav']),
      cellularPolicy: SyncCellularPolicy.parse(
        raw['cellularPolicy'] is String
            ? raw['cellularPolicy'] as String
            : null,
      ),
      manualPeers: manualPeers,
      notifiedPeers: notifiedPeers,
      lanHttpPort: _readInt(raw['lanHttpPort']),
      stampBaseline: _readBaseline(raw['stampSeq']),
      settingStamps: _readStamps(raw['settings']),
      scriptTombstones: _readStamps(raw['scriptTombstones']),
      scriptStamps: _readStamps(raw['scriptStamps']),
      knownScriptIds: knownScriptIds,
      activeScriptStamp: SyncStamp.fromJson(raw['activeScript']),
      sessionStamp: SyncStamp.fromJson(raw['sessionStamp']),
      coverStamps: _readStamps(raw['coverStamps']),
      coverTombstones: _readStamps(raw['coverTombstones']),
      lastSyncAt: _readInt(raw['lastSyncAt']),
      transportLastSuccess: _readIntMap(raw['transportLastSuccess']),
      snapshotPushSeq: _readIntMap(raw['snapshotPush']),
      log: _readLog(raw['log']),
      activity: _readActivity(raw['activity']),
      peers: peers.values.toList(),
      lanEndpoints: lanEndpoints.values.toList(),
    );
  }

  /// 端点合法性：可路由 IP 字面量、非空设备 id、端口在合法范围、有验证时间。
  ///
  /// `verifiedAt <= 0` 的端点不能进入表：没有验证时间的条目永远不会被
  /// 180 天淘汰规则命中，会永久留在状态里。运行时回写（`rememberLanEndpoint`）
  /// 与解码共用这一判据，避免两侧对「什么是合法端点」各有一套。
  static bool isValidLanEndpoint(LanPeerEndpoint endpoint) {
    if (endpoint.deviceId.trim().isEmpty) return false;
    if (!isRoutablePeerAddress(endpoint.host)) return false;
    if (endpoint.httpPort <= 0 || endpoint.httpPort > 65535) return false;
    if (endpoint.probePort < 0 || endpoint.probePort > 65535) return false;
    if (endpoint.verifiedAt <= 0) return false;
    return true;
  }

  static int _readInt(Object? raw) => raw is num ? raw.toInt() : 0;

  /// 单条解析失败（字段类型不符）只丢这一条，不拖垮整份状态。
  ///
  /// 条目级 `fromJson` 对类型仍是严格转换（`as num?` 等），持久化载荷被
  /// 手改 / 写坏时会抛 TypeError；这里是唯一的兜底点，保证解码总是不抛。
  static T? _tryParse<T>(T? Function(Object?) parse, Object? raw) {
    try {
      return parse(raw);
    } catch (_) {
      return null;
    }
  }

  static SyncVersion _readBaseline(Object? raw) {
    if (raw is! Map) return SyncVersion.zero;
    return SyncVersion.fromJson(raw) ?? SyncVersion.zero;
  }

  /// 登记表：键统一转字符串（JSON 键本来就是字符串），值无效则跳过该键。
  static Map<String, SyncStamp> _readStamps(Object? raw) {
    final stamps = <String, SyncStamp>{};
    if (raw is! Map) return stamps;
    for (final entry in raw.entries) {
      final stamp = SyncStamp.fromJson(entry.value);
      if (stamp != null) stamps[entry.key.toString()] = stamp;
    }
    return stamps;
  }

  /// kind → 时间 / 位置的整数映射；非数值条目跳过。
  static Map<String, int> _readIntMap(Object? raw) {
    final values = <String, int>{};
    if (raw is! Map) return values;
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is num) values[entry.key.toString()] = value.toInt();
    }
    return values;
  }

  static List<SyncLogEntry> _readLog(Object? raw) {
    final entries = <SyncLogEntry>[];
    if (raw is! List) return entries;
    for (final item in raw) {
      final entry = _tryParse(SyncLogEntry.fromJson, item);
      if (entry != null && entries.length < logLimit) entries.add(entry);
    }
    return entries;
  }

  static List<SyncActivityEntry> _readActivity(Object? raw) {
    final entries = <SyncActivityEntry>[];
    if (raw is! List) return entries;
    for (final item in raw) {
      final entry = _tryParse(SyncActivityEntry.fromJson, item);
      if (entry != null && entries.length < activityLimit) entries.add(entry);
    }
    return entries;
  }
}
