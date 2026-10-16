/// 跨设备数据同步的纯领域模型：记录 / 快照 / 合并规则。
///
/// 同步模型是「全量合并」：每台设备持有自己已知的完整视图（每条记录带
/// 版本三元组 [SyncVersion]，删除用墓碑记录表达），设备间交换视图后逐键
/// 取新，天然幂等、无需版本向量。信任模型：能解密同步口令者即已授权，
/// 不做逐项审批（见 ADR-0003）。
library;

/// 同步类别（设置页按类别开关；类别关闭时既不推送也不应用该类记录）。
enum SyncCategory {
  /// 列表头（含收藏 `__favorites__`）。
  playlists,

  /// 列表曲目行。
  playlistTracks,

  /// LX 音源脚本、排序 / 停用 / 音质、any-listen 连接配置。
  sources,

  /// 应用设置（跟人走的部分；省流 / 缓存 / 字体等设备相关项不在内）。
  settings,

  /// 凭证：AI Key、any-listen token 等（加密后随快照传输）。
  credentials,

  /// 听歌统计事件（append-only，按 `syncKey` 去重）。
  statistics,

  /// 播放历史（`play_history`，按曲目键合并，删除经墓碑）。
  history,

  /// 上次播放会话（队列/下标/进度/模式，用于换设备接着听）。
  session;

  static SyncCategory? tryParse(String? name) {
    for (final value in SyncCategory.values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// 记录键的编码约定（列表曲目等复合键的唯一实现）。
abstract final class SyncRecordKeys {
  /// 收藏列表的固定 syncId（跨设备稳定，不随自增 id 变化）。
  static const String favoritesPlaylistSyncId = '__favorites__';

  /// 当前激活的 LX 脚本（来源类别的单例记录）。
  static const String activeScriptKey = '__active_script__';

  /// 上次播放会话的单例记录。
  static const String sessionKey = '__playback_session__';

  static const String _separator = '\u0001';

  /// 播放历史键：平台 + 曲目 id（与 `play_history` 唯一键同构）。
  static String history(String sourceKey, String songId) =>
      '$sourceKey$_separator$songId';

  /// 解析播放历史键；格式非法返回 null。
  static ({String sourceKey, String songId})? parseHistory(String key) {
    final index = key.indexOf(_separator);
    if (index <= 0 || index >= key.length - 1) return null;
    return (
      sourceKey: key.substring(0, index),
      songId: key.substring(index + 1),
    );
  }

  /// 列表曲目复合键：列表 syncId + 平台 + 曲目 id。
  static String playlistTrack(String playlistSyncId, String sourceKey, String songId) =>
      '$playlistSyncId$_separator$sourceKey$_separator$songId';

  /// 解析列表曲目复合键；格式非法返回 null。
  static ({String playlistSyncId, String sourceKey, String songId})?
      parsePlaylistTrack(String key) {
    final parts = key.split(_separator);
    if (parts.length != 3) return null;
    return (
      playlistSyncId: parts[0],
      sourceKey: parts[1],
      songId: parts[2],
    );
  }
}

/// 记录版本戳（HLC-lite 三元组，见 ADR-0003 v2 §2）。
///
/// - [physical]：`max(本地物理时间, 已观测最大值)`。**不是**「最后修改的墙上
///   时间」——超前对端会把全组基线抬高，因此它可能大于本机时钟；
/// - [counter]：同一 `physical` 内的递增序号（同毫秒 / 时钟回拨），发号器保证
///   本机 `next()` 严格单调；
/// - [deviceId]：`(physical, counter)` 相等时按字典序决平局，保证确定性收敛；
///   空串表示未知来源（零值戳）。
///
/// 内容时间（`playedAt` / `endedAt` / `savedAt` / `importedAt` / 墓碑的真实
/// 删除时间）**不进版本戳**：它们是展示与语义字段，永不参与胜负判定。
class SyncVersion implements Comparable<SyncVersion> {
  const SyncVersion({
    required this.physical,
    this.counter = 0,
    this.deviceId = '',
  });

  /// 零值戳：未修改 / 未登记的默认版本（输给任何真实写入）。
  static const SyncVersion zero = SyncVersion(physical: 0);

  final int physical;
  final int counter;
  final String deviceId;

  /// [this] 是否严格新于 [other]（`(physical, counter, deviceId)` 字典序）。
  bool isNewerThan(SyncVersion other) => compareTo(other) > 0;

  @override
  int compareTo(SyncVersion other) {
    if (physical != other.physical) return physical.compareTo(other.physical);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return deviceId.compareTo(other.deviceId);
  }

  Map<String, Object?> toJson() => {
        'physical': physical,
        'counter': counter,
        if (deviceId.isNotEmpty) 'deviceId': deviceId,
      };

  /// 宽容解析：缺 physical 返回 null（解析方按 [zero] 兜底）。
  static SyncVersion? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final physical = raw['physical'];
    if (physical is! num) return null;
    return SyncVersion(
      physical: physical.toInt(),
      counter: (raw['counter'] as num?)?.toInt() ?? 0,
      deviceId: raw['deviceId'] is String ? raw['deviceId'] as String : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SyncVersion &&
      other.physical == physical &&
      other.counter == counter &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(physical, counter, deviceId);

  @override
  String toString() => 'SyncVersion($physical/$counter@$deviceId)';
}

/// 一条同步记录。删除 = `deleted` 为 true 的墓碑（`data` 为 null）。
class SyncRecord {
  final String key;
  final bool deleted;

  /// 版本三元组（[SyncVersion]）：跨设备胜负判定的唯一依据。
  final SyncVersion version;

  /// 类别载荷（JSON 友好；墓碑为 `{'deletedAt': ...}` 或 null）。
  ///
  /// 内容时间（`playedAt` / `endedAt` / `savedAt` / `importedAt`）都在这里，
  /// **永不参与胜负判定**（见 ADR-0003 v2 §2）。
  final Map<String, Object?>? data;

  const SyncRecord({
    required this.key,
    required this.version,
    this.deleted = false,
    this.data,
  });

  /// 墓碑记录；[deletedAt] 是真实删除时间（内容时间，删除 vs 播放的判据）。
  static SyncRecord tombstone({
    required String key,
    required SyncVersion version,
    int? deletedAt,
  }) =>
      SyncRecord(
        key: key,
        version: version,
        deleted: true,
        data: deletedAt == null ? null : {'deletedAt': deletedAt},
      );

  /// 墓碑的真实删除时间；缺省（非历史类别 / 异常数据）回退到版本物理分量。
  int get deletedAt {
    final value = data?['deletedAt'];
    return value is num ? value.toInt() : version.physical;
  }

  /// [this] 是否严格新于 [other]（`(physical, counter, deviceId)` 字典序）。
  bool isNewerThan(SyncRecord other) => version.isNewerThan(other.version);

  Map<String, dynamic> toJson() => {
        'key': key,
        if (deleted) 'deleted': true,
        'version': version.toJson(),
        if (data != null) 'data': data,
      };

  /// 宽容解析：缺 key 等必填字段返回 null（坏记录跳过而不是整体失败）。
  static SyncRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    if (key is! String || key.isEmpty) return null;
    final data = raw['data'];
    return SyncRecord(
      key: key,
      deleted: raw['deleted'] == true,
      version: SyncVersion.fromJson(raw['version']) ?? SyncVersion.zero,
      data: data is Map
          ? data.map((k, v) => MapEntry(k.toString(), v as Object?))
          : null,
    );
  }

  @override
  String toString() => 'SyncRecord($key, v=$version, d=$deleted)';
}

/// 一次同步快照：设备身份 + 各类别记录。
class SyncEnvelope {
  /// 线上协议版本（快照 JSON 的 `v` 字段值）。
  static const int protocolVersion = 2;

  /// 快照的协议版本（`v` 字段）；缺省按 [protocolVersion] 处理。
  ///
  /// 目前只有 v2 一种线上格式，没有按版本分支的行为；字段保留是为了让
  /// 快照自描述、便于将来做能力协商（见 ADR-0003 v2 §1）。
  final int version;

  final String deviceId;
  final String deviceName;
  final int producedAt;

  /// 记录集的规范化哈希（内容指纹）：与 [producedAt]（时间）分开表达
  /// 「内容变」与「时间变」。对端探测应答携带它，一致则跳过拉取。
  final String snapshotId;

  final Map<SyncCategory, List<SyncRecord>> records;

  const SyncEnvelope({
    required this.deviceId,
    this.deviceName = '',
    required this.producedAt,
    this.snapshotId = '',
    this.version = protocolVersion,
    this.records = const {},
  });

  /// 复制并替换内容指纹（引擎在裁剪墓碑后按最终记录集计算）。
  SyncEnvelope withSnapshotId(String snapshotId) => SyncEnvelope(
        deviceId: deviceId,
        deviceName: deviceName,
        producedAt: producedAt,
        snapshotId: snapshotId,
        version: version,
        records: records,
      );

  Iterable<SyncRecord> recordsOf(SyncCategory category) =>
      records[category] ?? const [];

  int get recordCount =>
      records.values.fold(0, (sum, list) => sum + list.length);

  /// 生成推送用快照：丢弃 [tombstoneRetentionMs] 之前的墓碑
  /// （墓碑长期保留会撑大快照；保留期外复活风险由保留期覆盖）。
  ///
  /// 保留期以**真实删除时间**（[SyncRecord.deletedAt]）为准，不是版本物理
  /// 分量：吸收超前戳会把版本抬到未来，用它算保留期会让墓碑永不淘汰。
  SyncEnvelope pruneTombstones({
    required int now,
    required int tombstoneRetentionMs,
  }) {
    final pruned = <SyncCategory, List<SyncRecord>>{};
    for (final entry in records.entries) {
      final kept = [
        for (final record in entry.value)
          if (!(record.deleted &&
              now - record.deletedAt > tombstoneRetentionMs))
            record,
      ];
      if (kept.isNotEmpty) pruned[entry.key] = kept;
    }
    return SyncEnvelope(
      deviceId: deviceId,
      deviceName: deviceName,
      producedAt: producedAt,
      snapshotId: snapshotId,
      version: version,
      records: pruned,
    );
  }

  Map<String, dynamic> toJson() => {
        'v': version,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'producedAt': producedAt,
        if (snapshotId.isNotEmpty) 'snapshotId': snapshotId,
        'records': {
          for (final entry in records.entries)
            if (entry.value.isNotEmpty)
              entry.key.name: [for (final record in entry.value) record.toJson()],
        },
      };

  /// 宽容解析：坏记录 / 未知类别跳过；不是对象返回 null。
  static SyncEnvelope? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final deviceId = raw['deviceId'];
    if (deviceId is! String || deviceId.isEmpty) return null;
    final records = <SyncCategory, List<SyncRecord>>{};
    final rawRecords = raw['records'];
    if (rawRecords is Map) {
      for (final entry in rawRecords.entries) {
        final category = SyncCategory.tryParse(entry.key.toString());
        if (category == null) continue;
        final list = entry.value;
        if (list is! List) continue;
        final parsed = <SyncRecord>[
          for (final item in list)
            if (SyncRecord.fromJson(item) case final record?) record,
        ];
        if (parsed.isNotEmpty) records[category] = parsed;
      }
    }
    return SyncEnvelope(
      deviceId: deviceId,
      deviceName: raw['deviceName'] is String ? raw['deviceName'] as String : '',
      producedAt: raw['producedAt'] is num
          ? (raw['producedAt'] as num).toInt()
          : 0,
      snapshotId:
          raw['snapshotId'] is String ? raw['snapshotId'] as String : '',
      version: (raw['v'] as num?)?.toInt() ?? protocolVersion,
      records: records,
    );
  }
}

/// 逐键取新：同一 key 保留版本三元组最大者；版本相等时
/// 保留先出现者（本地视图在前，保证确定性且避免同值抖动）。
Map<String, SyncRecord> mergeRecords(Iterable<SyncRecord> records) {
  final winners = <String, SyncRecord>{};
  for (final record in records) {
    final existing = winners[record.key];
    if (existing == null || record.isNewerThan(existing)) {
      winners[record.key] = record;
    }
  }
  return winners;
}

/// 合并多个快照同类别记录（[local] 在前，远端快照按传入顺序）。
Map<SyncCategory, Map<String, SyncRecord>> mergeEnvelopesByCategory(
  Iterable<SyncEnvelope> envelopes, {
  Set<SyncCategory>? categories,
}) {
  final merged = <SyncCategory, Map<String, SyncRecord>>{};
  for (final category in SyncCategory.values) {
    if (categories != null && !categories.contains(category)) continue;
    final all = <SyncRecord>[];
    var any = false;
    for (final envelope in envelopes) {
      final list = envelope.records[category];
      if (list == null || list.isEmpty) continue;
      any = true;
      all.addAll(list);
    }
    if (any) merged[category] = mergeRecords(all);
  }
  return merged;
}

/// 名册按最近接触时间倒序并截断到 [limit]（排序 / 淘汰的唯一实现，
/// 引擎内存名册与状态库落盘共用）。
List<SyncPeerState> trimPeers(Iterable<SyncPeerState> peers, int limit) {
  final recent = peers.toList()
    ..sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
  if (recent.length <= limit) return recent;
  return recent.sublist(0, limit);
}

/// 手动添加的对端地址（局域网发现不可用时的兜底：AP 隔离 / 多网段 / 防火墙）。
///
/// 只存用户输入的 `host` 与可选名称；`httpPort` 与 `deviceId` 在首次接触后
/// 由对端应答认领并回写——本机端口是动态的，对端记住本机才有意义
/// （见 ADR-0003 v2 §3）。`probePort` 为 0 时用传输的标准 UDP 端口。
class ManualPeer {
  const ManualPeer({
    required this.host,
    this.probePort = 0,
    this.httpPort = 0,
    this.deviceId = '',
    this.name = '',
  });

  /// 默认 UDP 探测端口（局域网传输的默认端口；`probePort` 为 0 时同此值）。
  static const int defaultProbePort = 47825;

  final String host;

  /// UDP 探测端口（0 = 用传输的标准端口）。
  final int probePort;

  /// 快照端点端口（0 = 尚未学到）。
  final int httpPort;

  /// 首次接触认领到的设备 id（'' = 尚未接触）。
  final String deviceId;

  final String name;

  ManualPeer copyWith({
    String? host,
    int? probePort,
    int? httpPort,
    String? deviceId,
    String? name,
  }) =>
      ManualPeer(
        host: host ?? this.host,
        probePort: probePort ?? this.probePort,
        httpPort: httpPort ?? this.httpPort,
        deviceId: deviceId ?? this.deviceId,
        name: name ?? this.name,
      );

  /// 回写学到的新观测（只覆盖已知字段，避免把已有信息抹成空）。
  ///
  /// [name] 只在条目尚未命名时填入：手动条目优先保留用户命名，
  /// 对端广播的设备名不覆盖用户输入。
  ManualPeer mergeLearned({int? httpPort, String? deviceId, String? name}) =>
      ManualPeer(
        host: host,
        probePort: probePort,
        httpPort: httpPort ?? this.httpPort,
        deviceId: (deviceId != null && deviceId.isNotEmpty) ? deviceId : this.deviceId,
        name: this.name.isNotEmpty
            ? this.name
            : (name != null && name.isNotEmpty ? name : ''),
      );

  Map<String, dynamic> toJson() => {
        'host': host,
        if (probePort > 0) 'probePort': probePort,
        if (httpPort > 0) 'httpPort': httpPort,
        if (deviceId.isNotEmpty) 'deviceId': deviceId,
        if (name.isNotEmpty) 'name': name,
      };

  static ManualPeer? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final host = raw['host'];
    if (host is! String || host.trim().isEmpty) return null;
    return ManualPeer(
      host: host.trim(),
      probePort: (raw['probePort'] as num?)?.toInt() ?? 0,
      httpPort: (raw['httpPort'] as num?)?.toInt() ?? 0,
      deviceId: raw['deviceId'] as String? ?? '',
      name: raw['name'] as String? ?? '',
    );
  }
}

/// 一轮同步的触发原因（报告与日志用；用户可从日志看出「为什么现在同步」）。
enum SyncTrigger {
  /// 启动后首轮。
  startup,

  /// 数据变更去抖。
  debounce,

  /// 周期定时。
  timer,

  /// 对端入站推送。
  incoming,

  /// 回前台补一轮。
  resume,

  /// 用户手动。
  manual;

  static SyncTrigger parse(String? name) {
    for (final value in SyncTrigger.values) {
      if (value.name == name) return value;
    }
    return SyncTrigger.timer;
  }
}

/// 一轮同步的结论（五态）。
///
/// 区分「没发现对端」与「没有变化」是这套模型的核心：两者都显示成
/// 「同步成功」时用户无法自查。判定规则见 `SyncEngine._resolveOutcome`。
enum SyncOutcome {
  /// 有对端可通信，且完成了数据流转（或有本地变更外发）。
  ok,

  /// 对端可达，但本机与对端都没有变化。
  noChanges,

  /// 没有任何对端可通信（未发现 / 未配置 / 传输不可用）。
  noPeers,

  /// 有失败也有成功（部分对端 / 部分传输）。
  partial,

  /// 整轮失败：无口令、异常，或所有对端都联系不上。
  failed;

  static SyncOutcome parse(String? name) {
    for (final value in SyncOutcome.values) {
      if (value.name == name) return value;
    }
    return SyncOutcome.ok;
  }
}

/// 同步失败原因（机器可读）：UI 按 [code] 映射本地化文案，[args] 给文案参数
/// （次数 / 对端名等）。
///
/// [detail] 是原始异常 / 技术细节，**只进 Logger 与「复制诊断信息」导出**，
/// UI 不展示原文（英文界面与不可读的 `$e` 都从这里隔离）。
class SyncIssue {
  const SyncIssue({required this.code, this.args = const {}, this.detail});

  /// 原因码（[SyncIssueCode]）。
  final String code;

  /// 文案参数（数值 / 名称；UI 映射时按 key 读取）。
  final Map<String, Object?> args;

  /// 原始技术细节（诊断用；UI 不展示）。
  final String? detail;

  Map<String, Object?> toJson() => {
        'code': code,
        if (args.isNotEmpty) 'args': args,
        if (detail != null && detail!.isNotEmpty) 'detail': detail,
      };

  /// 宽容解析：字符串按「未知原因 + 细节」处理（非结构化的持久化错误）。
  static SyncIssue? fromJson(Object? raw) {
    if (raw is String) {
      return raw.isEmpty
          ? null
          : SyncIssue(code: SyncIssueCode.unknown, detail: raw);
    }
    if (raw is! Map) return null;
    final code = raw['code'];
    if (code is! String || code.isEmpty) return null;
    final args = raw['args'];
    return SyncIssue(
      code: code,
      args: args is Map
          ? args.map((key, value) => MapEntry(key.toString(), value))
          : const {},
      detail: raw['detail'] is String ? raw['detail'] as String : null,
    );
  }

  @override
  String toString() => 'SyncIssue($code${detail == null ? '' : ', $detail'})';
}

/// 同步失败原因码（[SyncIssue.code]）。
///
/// `not_configured` / `start_failed` / `permission_denied` 与传输状态
/// （[SyncUnavailableReason]）同值：传输不可用与一轮失败共用一套文案映射。
abstract final class SyncIssueCode {
  /// 传输缺少必要配置（WebDAV 未填服务器地址）。
  static const String notConfigured = 'not_configured';

  /// 传输启动失败（端口占用、权限不足等）。
  static const String startFailed = 'start_failed';

  /// 局域网访问权限未授予（Android 17 起局域网默认阻断；手动地址同样无效）。
  static const String permissionDenied = 'permission_denied';

  /// 未设置同步口令。
  static const String noPassphrase = 'no_passphrase';

  /// 所有对端均不可达。
  static const String allPeersUnreachable = 'all_peers_unreachable';

  /// 传输 pull 抛异常（网络栈故障等）。
  static const String pullFailed = 'pull_failed';

  /// 传输 push 抛异常。
  static const String pushFailed = 'push_failed';

  /// 应用远端记录失败（args：`count` = 次数）。
  static const String applyFailed = 'apply_failed';

  /// 读取某个对端的快照失败（args：`peer` = 对端标识）。
  static const String peerReadFailed = 'peer_read_failed';

  /// 某个对端的快照解密失败 / 数据损坏（args：`peer`）。
  static const String peerDecryptFailed = 'peer_decrypt_failed';

  /// 推送某个对端失败（args：`peer`）。
  static const String peerPushFailed = 'peer_push_failed';

  /// 广播发送失败（网络策略 / 缺少广播 entitlement）。
  static const String broadcastUnavailable = 'broadcast_unavailable';

  /// 探测窗口内零应答（此前成功发现过设备，可能被网络隔离）。
  static const String discoverySilent = 'discovery_silent';

  /// WebDAV 目录准备失败（MKCOL）。
  static const String webdavDirFailed = 'webdav_dir_failed';

  /// WebDAV 目录列表失败（PROPFIND）。
  static const String webdavListFailed = 'webdav_list_failed';

  /// WebDAV 快照文件读取失败（args：`peer`）。
  static const String webdavReadFailed = 'webdav_read_failed';

  /// WebDAV 快照文件解密失败 / 数据损坏（args：`peer`）。
  static const String webdavDecryptFailed = 'webdav_decrypt_failed';

  /// WebDAV 快照上传失败。
  static const String webdavUploadFailed = 'webdav_upload_failed';

  /// 引擎内部异常（args 无；detail 带原始异常）。
  static const String internal = 'internal';

  /// 未知原因（非结构化错误 / 持久化中无法识别的形状）。
  static const String unknown = 'unknown';
}

/// 单个传输在一轮中的明细。
class SyncTransportReport {
  const SyncTransportReport({
    required this.kind,
    required this.running,
    this.enabled = false,
    this.unavailableReason,
    this.pulled = 0,
    this.pushed = 0,
    this.skippedUnchanged = 0,
    this.peersSeen = 0,
    this.failedPulls = 0,
    this.failedPushes = 0,
    this.bytesIn = 0,
    this.bytesOut = 0,
    this.durationMs = 0,
    this.error,
  });

  /// 传输标识（`lan` / `webdav`）。
  final String kind;

  /// 本轮该传输是否启用（未启用的传输不参与本轮，只出现在诊断信息里）。
  final bool enabled;

  /// 本轮开始时传输是否在运行。
  final bool running;

  /// 不可用原因码（`not_configured` / `start_failed` / `permission_denied`）；
  /// null = 可用。
  final String? unavailableReason;

  /// 成功接收并解密的远端快照数。
  final int pulled;

  /// 成功推送的对端数。
  final int pushed;

  /// 远端未变化而跳过的对端数。
  final int skippedUnchanged;

  /// 本轮探测到 / 列出的对端数（含未变与失败者）。
  final int peersSeen;

  final int failedPulls;
  final int failedPushes;
  final int bytesIn;
  final int bytesOut;
  final int durationMs;

  /// 本轮的失败原因（无失败为 null）；技术细节在 [SyncIssue.detail]。
  final SyncIssue? error;

  /// 本轮是否成功接触过对端（探测到对端、拉取或推送成功，且没有失败）。
  ///
  /// 名册「最后成功于」据此更新；探测到对端但无变化也算一次成功接触。
  bool get succeeded =>
      failedPulls == 0 &&
      failedPushes == 0 &&
      (peersSeen > 0 || pulled > 0 || pushed > 0);

  Map<String, Object?> toJson() => {
        'kind': kind,
        'enabled': enabled,
        'running': running,
        if (unavailableReason != null) 'unavailableReason': unavailableReason,
        'pulled': pulled,
        'pushed': pushed,
        if (skippedUnchanged > 0) 'skippedUnchanged': skippedUnchanged,
        'peersSeen': peersSeen,
        'failedPulls': failedPulls,
        'failedPushes': failedPushes,
        'bytesIn': bytesIn,
        'bytesOut': bytesOut,
        'durationMs': durationMs,
        if (error != null) 'error': error!.toJson(),
      };

  static SyncTransportReport fromJson(Object? raw) {
    if (raw is! Map) return const SyncTransportReport(kind: '', running: false);
    int intOf(String key) => (raw[key] as num?)?.toInt() ?? 0;
    return SyncTransportReport(
      kind: raw['kind'] as String? ?? '',
      enabled: raw['enabled'] == true,
      running: raw['running'] == true,
      unavailableReason:
          raw['unavailableReason'] is String ? raw['unavailableReason'] as String : null,
      pulled: intOf('pulled'),
      pushed: intOf('pushed'),
      skippedUnchanged: intOf('skippedUnchanged'),
      peersSeen: intOf('peersSeen'),
      failedPulls: intOf('failedPulls'),
      failedPushes: intOf('failedPushes'),
      bytesIn: intOf('bytesIn'),
      bytesOut: intOf('bytesOut'),
      durationMs: intOf('durationMs'),
      error: SyncIssue.fromJson(raw['error']),
    );
  }
}

/// 名册里的一台对端（最近一次接触的观测值；持久化在同步状态里）。
class SyncPeerState {
  const SyncPeerState({
    required this.deviceId,
    this.name = '',
    this.transport = '',
    this.lastSeenAt = 0,
    this.lastPullAt = 0,
    this.lastPushAt = 0,
    this.lastError,
    this.behindBy,
    this.clockSkewMs,
  });

  final String deviceId;
  final String name;
  final String transport;

  /// 最近一次接触（拉取或推送尝试）的时间。
  final int lastSeenAt;

  /// 最近一次成功拉取该对端快照的时间。
  final int lastPullAt;

  /// 最近一次成功推送的时间。
  final int lastPushAt;

  /// 最近一次接触的失败原因；成功接触时清除（见 `SyncEngine._roster`）。
  final SyncIssue? lastError;

  /// 落后条数（增量协议提供；null = 未知，见增量协议任务）。
  final int? behindBy;

  /// 对端时钟偏移（对端自报 `producedAt` − 本机时间；正 = 偏快）。
  final int? clockSkewMs;

  SyncPeerState copyWith({
    String? name,
    String? transport,
    int? lastSeenAt,
    int? lastPullAt,
    int? lastPushAt,
    SyncIssue? lastError,
    bool clearLastError = false,
    int? behindBy,
    int? clockSkewMs,
  }) =>
      SyncPeerState(
        deviceId: deviceId,
        name: name ?? this.name,
        transport: transport ?? this.transport,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        lastPullAt: lastPullAt ?? this.lastPullAt,
        lastPushAt: lastPushAt ?? this.lastPushAt,
        lastError: clearLastError ? null : (lastError ?? this.lastError),
        behindBy: behindBy ?? this.behindBy,
        clockSkewMs: clockSkewMs ?? this.clockSkewMs,
      );

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        if (name.isNotEmpty) 'name': name,
        if (transport.isNotEmpty) 'transport': transport,
        if (lastSeenAt > 0) 'lastSeenAt': lastSeenAt,
        if (lastPullAt > 0) 'lastPullAt': lastPullAt,
        if (lastPushAt > 0) 'lastPushAt': lastPushAt,
        if (lastError != null) 'lastError': lastError!.toJson(),
        if (behindBy != null) 'behindBy': behindBy,
        if (clockSkewMs != null) 'clockSkewMs': clockSkewMs,
      };

  static SyncPeerState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final deviceId = raw['deviceId'];
    if (deviceId is! String || deviceId.isEmpty) return null;
    return SyncPeerState(
      deviceId: deviceId,
      name: raw['name'] as String? ?? '',
      transport: raw['transport'] as String? ?? '',
      lastSeenAt: (raw['lastSeenAt'] as num?)?.toInt() ?? 0,
      lastPullAt: (raw['lastPullAt'] as num?)?.toInt() ?? 0,
      lastPushAt: (raw['lastPushAt'] as num?)?.toInt() ?? 0,
      lastError: SyncIssue.fromJson(raw['lastError']),
      behindBy: (raw['behindBy'] as num?)?.toInt(),
      clockSkewMs: (raw['clockSkewMs'] as num?)?.toInt(),
    );
  }
}

/// 一轮同步的结果对象（UI 状态、日志与诊断导出共用）。
class SyncRoundReport {
  const SyncRoundReport({
    required this.trigger,
    required this.startedAt,
    required this.finishedAt,
    required this.outcome,
    this.applied = 0,
    this.applyFailures = 0,
    this.transports = const [],
    this.peers = const [],
    this.remoteRecords = 0,
    this.error,
  });

  final SyncTrigger trigger;
  final int startedAt;
  final int finishedAt;
  final SyncOutcome outcome;

  /// 本轮实际落地的记录数（变更量，不随库大小增长）。
  final int applied;

  /// 本轮写回本地失败的适配器次数（数据未落地，入站快照会重试）。
  final int applyFailures;

  /// 本轮参与（或本应参与）的传输明细。
  final List<SyncTransportReport> transports;

  /// 本轮接触过的对端（名册快照）。
  final List<SyncPeerState> peers;

  /// 本轮收到的远端记录数（未去重前）。
  final int remoteRecords;

  /// 本轮的失败原因（无失败为 null）；技术细节在 [SyncIssue.detail]。
  final SyncIssue? error;

  int get durationMs => finishedAt - startedAt;

  int get failedCount =>
      transports.fold(0, (sum, t) => sum + t.failedPulls + t.failedPushes) +
      applyFailures;

  int get peersSeen => transports.fold(0, (sum, t) => sum + t.peersSeen);

  int get bytesIn => transports.fold(0, (sum, t) => sum + t.bytesIn);

  int get bytesOut => transports.fold(0, (sum, t) => sum + t.bytesOut);

  @override
  String toString() =>
      'SyncRoundReport(${trigger.name}/${outcome.name}, applied=$applied, '
      'peers=$peersSeen, failed=$failedCount'
      '${error == null ? '' : ', error=${error!.code}'})';
}

/// 列表头同步记录（自增 id 不出本机；`syncId` 跨设备稳定，收藏为固定常量）。
///
/// 与 `syncExportPlaylists` / `syncApplyLibrary` 的 JSON 形状一一对应；
/// 列名 / 行结构只存在于资料库实现内部。`createdAt` 是内容时间；
/// [version] 是唯一的胜负判据。
class PlaylistSyncRecord {
  const PlaylistSyncRecord({
    required this.syncId,
    required this.name,
    required this.createdAt,
    required this.version,
  });

  final String syncId;
  final String name;
  final int createdAt;
  final SyncVersion version;

  Map<String, Object?> toJson() => {
        'syncId': syncId,
        'name': name,
        'createdAt': createdAt,
        'version': version.toJson(),
      };

  /// 宽容解析：缺失 / 类型不符按空值处理（由应用侧按需跳过并计数）。
  ///
  /// [version] 以记录信封的版本为准（信封是权威；data 内的版本只用于
  /// 自包含备份文件的解析）。
  static PlaylistSyncRecord fromJson(
    Map<String, Object?> data, {
    SyncVersion? version,
  }) =>
      PlaylistSyncRecord(
        syncId: data['syncId'] as String? ?? '',
        name: data['name'] as String? ?? '',
        createdAt: (data['createdAt'] as num?)?.toInt() ?? 0,
        version: version ??
            SyncVersion.fromJson(data['version']) ??
            SyncVersion.zero,
      );
}

/// 列表曲目同步记录（合并键 = `playlistSyncId + sourceKey + songId`）。
class PlaylistTrackSyncRecord {
  const PlaylistTrackSyncRecord({
    required this.playlistSyncId,
    required this.sourceKey,
    required this.songId,
    required this.title,
    required this.artist,
    required this.album,
    required this.coverUrl,
    required this.durationMs,
    required this.raw,
    required this.addedAt,
    required this.sortOrder,
    required this.version,
  });

  final String playlistSyncId;
  final String sourceKey;
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? durationMs;

  /// 平台原始对象（JSON 字符串，原样回传给脚本）。
  final String raw;
  final int addedAt;
  final int sortOrder;
  final SyncVersion version;

  Map<String, Object?> toJson() => {
        'playlistSyncId': playlistSyncId,
        'sourceKey': sourceKey,
        'songId': songId,
        'title': title,
        'artist': artist,
        'album': album,
        'coverUrl': coverUrl,
        'durationMs': durationMs,
        'raw': raw,
        'addedAt': addedAt,
        'sortOrder': sortOrder,
        'version': version.toJson(),
      };

  static PlaylistTrackSyncRecord fromJson(
    Map<String, Object?> data, {
    SyncVersion? version,
  }) =>
      PlaylistTrackSyncRecord(
        playlistSyncId: data['playlistSyncId'] as String? ?? '',
        sourceKey: data['sourceKey'] as String? ?? '',
        songId: data['songId'] as String? ?? '',
        title: data['title'] as String? ?? '',
        artist: data['artist'] as String? ?? '',
        album: data['album'] as String? ?? '',
        coverUrl: data['coverUrl'] as String?,
        durationMs: (data['durationMs'] as num?)?.toInt(),
        raw: data['raw'] as String? ?? '{}',
        addedAt: (data['addedAt'] as num?)?.toInt() ?? 0,
        sortOrder: (data['sortOrder'] as num?)?.toInt() ?? 0,
        version: version ??
            SyncVersion.fromJson(data['version']) ??
            SyncVersion.zero,
      );
}

/// 播放历史同步记录（`playedAt` 是内容时间，不参与胜负判定）。
class PlayHistorySyncRecord {
  const PlayHistorySyncRecord({
    required this.sourceKey,
    required this.songId,
    required this.title,
    required this.artist,
    required this.album,
    required this.coverUrl,
    required this.durationMs,
    required this.raw,
    required this.playedAt,
    required this.version,
  });

  final String sourceKey;
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? durationMs;
  final String raw;

  /// 何时听的（内容时间；展示与删除 vs 播放的判据）。
  final int playedAt;
  final SyncVersion version;

  Map<String, Object?> toJson() => {
        'sourceKey': sourceKey,
        'songId': songId,
        'title': title,
        'artist': artist,
        'album': album,
        'coverUrl': coverUrl,
        'durationMs': durationMs,
        'raw': raw,
        'playedAt': playedAt,
        'version': version.toJson(),
      };

  static PlayHistorySyncRecord fromJson(
    Map<String, Object?> data, {
    SyncVersion? version,
  }) =>
      PlayHistorySyncRecord(
        sourceKey: data['sourceKey'] as String? ?? '',
        songId: data['songId'] as String? ?? '',
        title: data['title'] as String? ?? '',
        artist: data['artist'] as String? ?? '',
        album: data['album'] as String? ?? '',
        coverUrl: data['coverUrl'] as String?,
        durationMs: (data['durationMs'] as num?)?.toInt(),
        raw: data['raw'] as String? ?? '{}',
        playedAt: (data['playedAt'] as num?)?.toInt() ?? 0,
        version: version ??
            SyncVersion.fromJson(data['version']) ??
            SyncVersion.zero,
      );
}

/// 资料库墓碑记录（删除也取新：`category + key` + 版本三元组）。
///
/// [deletedAt] 是真实删除时间（内容时间）：历史「删除 vs 播放」用它判定，
/// 其它类别只作诊断。**不**参与胜负判定。
class SyncTombstoneRecord {
  const SyncTombstoneRecord({
    required this.category,
    required this.key,
    required this.version,
    required this.deletedAt,
  });

  final String category;
  final String key;
  final SyncVersion version;
  final int deletedAt;

  Map<String, Object?> toJson() => {
        'category': category,
        'key': key,
        'version': version.toJson(),
        'deletedAt': deletedAt,
      };

  static SyncTombstoneRecord fromJson(
    Map<String, Object?> data, {
    SyncVersion? version,
  }) =>
      SyncTombstoneRecord(
        category: data['category'] as String? ?? '',
        key: data['key'] as String? ?? '',
        version: version ??
            SyncVersion.fromJson(data['version']) ??
            SyncVersion.zero,
        deletedAt: (data['deletedAt'] as num?)?.toInt() ??
            (data['version'] is Map
                ? ((data['version'] as Map)['physical'] as num?)?.toInt() ?? 0
                : 0),
      );
}
