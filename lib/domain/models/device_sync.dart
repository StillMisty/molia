/// 跨设备数据同步的纯领域模型：记录 / 快照 / 合并规则。
///
/// 同步模型是「全量合并 + 增量日志」：每台设备持有自己已知的完整视图（每条
/// 记录带版本三元组 [SyncVersion]，删除用墓碑记录表达），设备间交换视图后逐键
/// 取新；日常轮次只交换**变更**（[SyncJournalEntry] 组成的增量窗口），首次引导
/// 与长期离线用全量快照兜底（见 [SyncEnvelope]）。信任模型：能解密同步口令者
/// 即已授权，不做逐项审批（见 ADR-0003）。
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
  session,

  /// 自定义封面（每曲 + 全局默认封面图片，体积大）。
  ///
  /// 默认关闭：自动同步只在用户显式开启后才外发封面；关闭期间本地修改仍会
  /// 登记，重新开启后由全量快照 / 后续变更外发。手动完整备份不受此开关限制
  /// （导出 / 导入仍含封面）。
  covers;

  /// 类别默认开关（新装 / 旧状态缺失该类别时使用）。
  bool get defaultEnabled => this != SyncCategory.covers;

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

  /// 全局默认封面的单例记录键（`covers` 类别）。
  static const String defaultCoverKey = '__default_cover__';

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

  /// [this] 是否严格旧于 [other]。
  bool isOlderThan(SyncVersion other) => compareTo(other) < 0;

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

/// 增量日志条目：一次本地变更在 journal 里的记录。
///
/// [seq] 是产生该条目的设备上单调递增的序号（**跨设备语义 = 对端游标**：
/// 接收方只应用 `seq > 游标` 的条目）；[category] 与 [record] 就是该变更
/// 的同步记录（键 / 版本三元组 / 墓碑 / 载荷），与全量快照里的记录同构。
class SyncJournalEntry {
  const SyncJournalEntry({
    required this.seq,
    required this.category,
    required this.record,
  });

  final int seq;
  final SyncCategory category;
  final SyncRecord record;

  Map<String, dynamic> toJson() => {
        'seq': seq,
        'category': category.name,
        'record': record.toJson(),
      };

  /// 宽容解析：seq / category 非法返回 null（坏条目跳过）。
  static SyncJournalEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final seq = raw['seq'];
    if (seq is! num || seq.toInt() <= 0) return null;
    final category = SyncCategory.tryParse(raw['category']?.toString());
    if (category == null) return null;
    final record = SyncRecord.fromJson(raw['record']);
    if (record == null) return null;
    return SyncJournalEntry(seq: seq.toInt(), category: category, record: record);
  }

  @override
  String toString() => 'SyncJournalEntry($seq, ${category.name}, ${record.key})';
}

/// 一次同步快照：设备身份 + 各类别记录；也可以是只携带变更的**增量窗口**。
///
/// 载荷两种形态（同一线上类型，[journal] 是否为 null 区分）：
/// - **全量快照**（`journal == null`）：完整记录集，用于首次引导（bootstrap）、
///   anti-entropy 兜底与完整备份；[journalHead] 是快照覆盖到的 journal 位置，
///   接收方应用后把游标推进到该位置；
/// - **增量窗口**（`journal != null`，可为空列表）：只携带 `seq > 接收方游标`
///   的条目；[windowStart] / [windowEnd] 是窗口边界，[baseSeq] 是发送方已
///   裁剪到的位置——接收方游标小于 [baseSeq] 时必须改走 bootstrap。
///
/// [acks] 是「我已消费各对端 journal 到哪」的回执：对端据此 compact
/// （`min(对端 ack)` 裁剪日志）。
class SyncEnvelope {
  /// 线上协议版本（载荷自描述字段的 `v`；帧层版本见 `SyncCodec.version`）。
  ///
  /// 协议自始为 v3：只写 v3、只读 v3，不做版本协商与降级（ADR-0003 §1 修订）。
  /// 字段保留是让载荷自描述、便于排障与备份识别，不参与任何分支。
  static const int protocolVersion = 3;

  /// 载荷的协议版本（自描述字段）；缺省按 [protocolVersion] 处理。
  final int version;

  final String deviceId;
  final String deviceName;
  final int producedAt;

  /// 记录集的规范化哈希（内容指纹）：与 [producedAt]（时间）分开表达
  /// 「内容变」与「时间变」。对端探测应答携带它，一致则跳过拉取；
  /// anti-entropy 也用它比对「静默分歧」。
  final String snapshotId;

  final Map<SyncCategory, List<SyncRecord>> records;

  /// 发送方 journal 头部 seq（0 = 尚无条目）：全量快照携带的是快照覆盖到的
  /// 位置（应用后游标推进到这里），增量载荷携带的是发送方当前头部。
  final int journalHead;

  /// 发送方已裁剪到的位置（窗口起点 = [baseSeq] + 1）；接收方游标小于它
  /// 时日志窗口已不完整，必须请求 bootstrap 全量快照。
  final int baseSeq;

  /// 增量窗口的第一个 seq（0 = 空窗口）。
  final int windowStart;

  /// 增量窗口的最后一个 seq（0 = 空窗口）。
  final int windowEnd;

  /// 增量条目；null = 本载荷是全量快照（见类文档）。
  final List<SyncJournalEntry>? journal;

  /// 我已消费各对端 journal 的位置（对端 id → seq）：对端据此裁剪日志。
  final Map<String, int> acks;

  /// 本载荷记录集覆盖的类别（发送方本轮启用的类别；蜂窝小类别轮只含小类别）。
  ///
  /// anti-entropy 只在双方共享的类别上比对 [snapshotId]——类别开关不同的
  /// 设备不会被误判为「内容不一致」。
  final List<String> categories;

  const SyncEnvelope({
    required this.deviceId,
    this.deviceName = '',
    required this.producedAt,
    this.snapshotId = '',
    this.version = protocolVersion,
    this.records = const {},
    this.journalHead = 0,
    this.baseSeq = 0,
    this.windowStart = 0,
    this.windowEnd = 0,
    this.journal,
    this.acks = const {},
    this.categories = const [],
  });

  /// 本载荷是否为增量窗口（null journal = 全量快照）。
  bool get isDelta => journal != null;

  /// 载荷携带的记录（增量载荷从 [journal] 提取，全量快照用 [records]）。
  Map<SyncCategory, List<SyncRecord>> get payloadRecords {
    final entries = journal;
    if (entries == null) return records;
    final result = <SyncCategory, List<SyncRecord>>{};
    for (final entry in entries) {
      result.putIfAbsent(entry.category, () => []).add(entry.record);
    }
    return result;
  }

  /// 复制并替换内容指纹（引擎在裁剪墓碑后按最终记录集计算）。
  SyncEnvelope withSnapshotId(String snapshotId) => SyncEnvelope(
        deviceId: deviceId,
        deviceName: deviceName,
        producedAt: producedAt,
        snapshotId: snapshotId,
        version: version,
        records: records,
        journalHead: journalHead,
        baseSeq: baseSeq,
        windowStart: windowStart,
        windowEnd: windowEnd,
        journal: journal,
        acks: acks,
        categories: categories,
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
      journalHead: journalHead,
      baseSeq: baseSeq,
      acks: acks,
      categories: categories,
    );
  }

  Map<String, dynamic> toJson() => {
        'v': version,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'producedAt': producedAt,
        if (snapshotId.isNotEmpty) 'snapshotId': snapshotId,
        if (journalHead > 0) 'journalHead': journalHead,
        if (baseSeq > 0) 'baseSeq': baseSeq,
        if (journal != null) ...{
          'windowStart': windowStart,
          'windowEnd': windowEnd,
          'journal': [for (final entry in journal!) entry.toJson()],
        },
        if (acks.isNotEmpty)
          'acks': {for (final entry in acks.entries) entry.key: entry.value},
        if (categories.isNotEmpty) 'categories': categories,
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
    // `journal` 字段存在即增量载荷（空列表也是合法的空窗口）。
    List<SyncJournalEntry>? journal;
    final rawJournal = raw['journal'];
    if (rawJournal is List) {
      journal = <SyncJournalEntry>[
        for (final item in rawJournal)
          if (SyncJournalEntry.fromJson(item) case final entry?) entry,
      ];
    }
    final acks = <String, int>{};
    final rawAcks = raw['acks'];
    if (rawAcks is Map) {
      for (final entry in rawAcks.entries) {
        final value = entry.value;
        if (entry.key is String && value is num) {
          acks[entry.key as String] = value.toInt();
        }
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
      journalHead: (raw['journalHead'] as num?)?.toInt() ?? 0,
      baseSeq: (raw['baseSeq'] as num?)?.toInt() ?? 0,
      windowStart: (raw['windowStart'] as num?)?.toInt() ?? 0,
      windowEnd: (raw['windowEnd'] as num?)?.toInt() ?? 0,
      journal: journal,
      acks: acks,
      categories:
          (raw['categories'] as List?)?.whereType<String>().toList() ?? const [],
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
  /// 对端广播的设备名不覆盖用户输入。UDP 探测端口**不参与学习**：
  /// 对端的来源端口随 NAT / 独立降级 / 重启变化，写回会污染用户配置
  /// （学到 [httpPort] 后直连不再依赖 UDP 探测）。
  ManualPeer mergeLearned({int? httpPort, String? deviceId, String? name}) =>
      ManualPeer(
        host: host,
        // 保留条目自身的探测端口（不参与学习，见文档注释）。
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

/// 局域网发现层观测到的对端（认证通过的公告 / 应答）。
///
/// [host] 是 UDP 来源地址（IPv6 组播源可能是 link-local），[snapshotId] /
/// [journalHead] 供「内容未变跳过 GET」使用，[bootId] 让对端重启在 head
/// 未变时也能被识别为重新上线。
class LanPeerSighting {
  const LanPeerSighting({
    required this.deviceId,
    required this.name,
    required this.host,
    required this.httpPort,
    required this.probePort,
    required this.snapshotId,
    required this.journalHead,
    required this.bootId,
    required this.observedAt,
  });

  final String deviceId;
  final String name;
  final String host;
  final int httpPort;
  final int probePort;
  final String snapshotId;
  final int? journalHead;
  final String bootId;

  /// 观测时间（毫秒时间戳）。
  final int observedAt;
}

/// 已通过「MAC 验证 + HTTP 解密成功」的持久化端点（#42 落库）。
///
/// 地址只存可路由字面量；[verifiedAt] 用于 180 天淘汰，[probePort] 用于
/// 广播被隔离时的单播兜底。
class LanPeerEndpoint {
  const LanPeerEndpoint({
    required this.deviceId,
    required this.host,
    required this.httpPort,
    this.probePort = 0,
    required this.verifiedAt,
  });

  final String deviceId;
  final String host;
  final int httpPort;
  final int probePort;

  /// 最近一次验证成功（毫秒时间戳）。
  final int verifiedAt;

  LanPeerEndpoint copyWith({
    String? deviceId,
    String? host,
    int? httpPort,
    int? probePort,
    int? verifiedAt,
  }) =>
      LanPeerEndpoint(
        deviceId: deviceId ?? this.deviceId,
        host: host ?? this.host,
        httpPort: httpPort ?? this.httpPort,
        probePort: probePort ?? this.probePort,
        verifiedAt: verifiedAt ?? this.verifiedAt,
      );

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'host': host,
        'httpPort': httpPort,
        if (probePort > 0) 'probePort': probePort,
        'verifiedAt': verifiedAt,
      };

  static LanPeerEndpoint? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final deviceId = raw['deviceId'];
    final host = raw['host'];
    final httpPort = (raw['httpPort'] as num?)?.toInt() ?? 0;
    final verifiedAt = (raw['verifiedAt'] as num?)?.toInt() ?? 0;
    if (deviceId is! String || deviceId.isEmpty) return null;
    if (host is! String || host.trim().isEmpty) return null;
    if (httpPort <= 0 || httpPort > 65535) return null;
    return LanPeerEndpoint(
      deviceId: deviceId,
      host: host.trim(),
      httpPort: httpPort,
      probePort: (raw['probePort'] as num?)?.toInt() ?? 0,
      verifiedAt: verifiedAt,
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

  /// 退后台前的尽力推送。
  pause,

  /// 网络变化（connectivity 事件）触发的强制发现轮。
  network,

  /// 收到对端公告（新设备 / 新内容 / 重启）触发的发现轮。
  discovery,

  /// 打开同步页自动检查连接状态（受省电 / 蜂窝策略约束，不是手动轮）。
  check,

  /// 用户手动。
  manual;

  static SyncTrigger parse(String? name) {
    for (final value in SyncTrigger.values) {
      if (value.name == name) return value;
    }
    return SyncTrigger.timer;
  }
}

/// 同步等级（ADR-0003 v2 §4）：什么时候跑同步是可测策略，不是散落的定时器。
///
/// - [active]：界面可见且（正在播放 / 最近有交互 / 刚有数据变更）——变更去抖
///   3–5s 后跑一轮，只探测或拉「变化」对端（传输门控负责）；
/// - [idle]：前台但无交互——退避 10→20→40→60 分钟封顶；**无本地变更不广播、
///   不发 PROPFIND**（空闲唤醒只为外发本地变更，或充电 + Wi-Fi 的 anti-entropy
///   全量校验）；
/// - [background]：锁屏 / 退后台——**零定时唤醒**；`onAppHidden` 尽力推一次、
///   `onAppVisible` 拉一次；
/// - [powerSave]：低电量未充电或系统省电模式——暂停自动同步，仅手动触发。
enum SyncLevel { active, idle, background, powerSave }

/// 蜂窝网络下的自动同步策略（与省流模式联动；用户可在同步设置页切换）。
enum SyncCellularPolicy {
  /// 只同步小类别（设置 / 歌单 / 会话等）：统计与历史等大类别留到 Wi-Fi。
  auto,

  /// 移动数据下暂停自动同步（仅手动触发）。
  pause;

  static SyncCellularPolicy parse(String? name) {
    for (final value in SyncCellularPolicy.values) {
      if (value.name == name) return value;
    }
    return SyncCellularPolicy.auto;
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
/// [detail] 是原始异常 / 技术细节，**只进 Logger 与日志子页的失败详情**，
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

  /// UDP 探测端口不可用（IPv4 / IPv6 绑定均失败：端口被系统保留或被占用）。
  ///
  /// 与 [startFailed] 的区别：HTTP 端点正常、传输在运行，只有发现降级；
  /// 出路是「添加设备」手动地址直连或改用 WebDAV。
  static const String probePortUnavailable = 'probe_port_unavailable';

  /// 探测窗口内零应答（本进程发现过设备、本轮无响应，可能被网络隔离）。
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

  /// 显式清理对端远端文件失败（args：`peer` = 对端标识）。
  static const String deleteRemoteFailed = 'delete_remote_failed';

  /// 未知原因（非结构化错误 / 持久化中无法识别的形状）。
  static const String unknown = 'unknown';

  /// 全部原因码（文案完备性护栏：新增码必须补专属文案并登记到这里，
  /// 测试按此迭代断言「每码有专属文案」）。
  static const List<String> all = [
    notConfigured,
    startFailed,
    permissionDenied,
    noPassphrase,
    allPeersUnreachable,
    pullFailed,
    pushFailed,
    applyFailed,
    peerReadFailed,
    peerDecryptFailed,
    peerPushFailed,
    broadcastUnavailable,
    probePortUnavailable,
    discoverySilent,
    webdavDirFailed,
    webdavListFailed,
    webdavReadFailed,
    webdavDecryptFailed,
    webdavUploadFailed,
    deleteRemoteFailed,
    internal,
    unknown,
  ];
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
    this.lastSuccessAt = 0,
    this.lastPullAt = 0,
    this.lastPushAt = 0,
    this.lastError,
    this.behindBy,
    this.behindBytes,
    this.clockSkewMs,
    this.cursorSeq = -1,
    this.ackedSeq = -1,
    this.snapshotId = '',
    this.categories = const [],
    this.fullPulledAt = 0,
  });

  /// 失联阈值：超过这段时间没有任何接触的对端在名册里标记「已失联」
  /// （只提示与提供处置动作，不做自动删除）。
  static const int lostThresholdMs = 180 * 24 * 60 * 60 * 1000;

  final String deviceId;
  final String name;
  final String transport;

  /// 最近一次接触（成功或失败的尝试）的时间。
  ///
  /// 失败尝试也刷新它：界面用「本轮是否尝试过」区分「未连接」与「本轮没
  /// 尝试」；失联判定不看它（见 [isLostAt]）。
  final int lastSeenAt;

  /// 最近一次真正接触成功的时间（探测应答 / 未变跳过 / 拉取或推送成功）。
  ///
  /// 0 = 未知（旧状态没有这个字段，或从未成功过）。判断「已连接 / 失联」
  /// 一律以它为准，失败尝试不续命；旧状态用 [effectiveLastSuccessAt] 兜底。
  final int lastSuccessAt;

  /// 最近一次成功拉取该对端快照的时间。
  final int lastPullAt;

  /// 最近一次成功推送的时间。
  final int lastPushAt;

  /// 最近一次接触的失败原因；成功接触时清除（见 `SyncRoundRunner`）。
  final SyncIssue? lastError;

  /// 兼容旧状态的有效成功时间：新状态直接用 [lastSuccessAt]；旧状态没有
  /// 该字段时取「最近一次数据流转（拉取 / 推送）」与「没有失败记录的最后
  /// 尝试」中的较新者——老名册不该因为升级后缺字段就显示成「还没连上」，
  /// 也不能让 200 天前的数据时间盖过昨天探测成功的证据。
  ///
  /// 失败尝试不算成功：旧状态只要还有 [lastError]，[lastSeenAt] 就不参与
  /// 兜底（它可能只是最近一次失败）。返回 0 = 从未成功接触。
  int get effectiveLastSuccessAt {
    if (lastSuccessAt > 0) return lastSuccessAt;
    final lastData = lastPullAt > lastPushAt ? lastPullAt : lastPushAt;
    final legacyAttempt = lastError == null ? lastSeenAt : 0;
    return lastData > legacyAttempt ? lastData : legacyAttempt;
  }

  /// 对端落后本机 journal 的条数（本机头部 − 对端已 ack 的位置）；
  /// null = 对端尚未 ack 过（无观测）。
  final int? behindBy;

  /// 对端落后部分的近似字节量（与 [behindBy] 同源）。
  final int? behindBytes;

  /// 对端时钟偏移（对端自报 `producedAt` − 本机时间；正 = 偏快）。
  final int? clockSkewMs;

  /// 本机已消费该对端 journal 到的位置（游标）；-1 = 尚未消费过任何条目。
  final int cursorSeq;

  /// 该对端已确认消费本机 journal 到的位置（来自对端载荷的 ack）；
  /// -1 = 未知（从未收到对端的 ack，视为可能落后任何位置）。
  final int ackedSeq;

  /// 该对端最近一次自报的全量视图指纹（anti-entropy 比对用）。
  final String snapshotId;

  /// 该对端自报的启用类别（anti-entropy 只在双方共享的类别上比对指纹）。
  final List<String> categories;

  /// 最近一次为该对端做全量兜底的时间（节流：同一对端不频繁重拉）。
  final int fullPulledAt;

  /// 是否已失联（超过 [lostThresholdMs] 没有**成功**接触）。
  ///
  /// 唯一判据是 [effectiveLastSuccessAt]：失败尝试不续命；从未成功接触过的
  /// 设备返回 false（界面显示「还没连上 / 未连接」，不是「已失联」）。
  bool isLostAt(int nowMs) {
    final lastSuccess = effectiveLastSuccessAt;
    return lastSuccess > 0 && nowMs - lastSuccess > lostThresholdMs;
  }

  SyncPeerState copyWith({
    String? name,
    String? transport,
    int? lastSeenAt,
    int? lastSuccessAt,
    int? lastPullAt,
    int? lastPushAt,
    SyncIssue? lastError,
    bool clearLastError = false,
    int? behindBy,
    bool clearBehind = false,
    int? behindBytes,
    int? clockSkewMs,
    int? cursorSeq,
    int? ackedSeq,
    String? snapshotId,
    List<String>? categories,
    int? fullPulledAt,
  }) =>
      SyncPeerState(
        deviceId: deviceId,
        name: name ?? this.name,
        transport: transport ?? this.transport,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
        lastPullAt: lastPullAt ?? this.lastPullAt,
        lastPushAt: lastPushAt ?? this.lastPushAt,
        lastError: clearLastError ? null : (lastError ?? this.lastError),
        behindBy: clearBehind ? null : (behindBy ?? this.behindBy),
        behindBytes: clearBehind ? null : (behindBytes ?? this.behindBytes),
        clockSkewMs: clockSkewMs ?? this.clockSkewMs,
        cursorSeq: cursorSeq ?? this.cursorSeq,
        ackedSeq: ackedSeq ?? this.ackedSeq,
        snapshotId: snapshotId ?? this.snapshotId,
        categories: categories ?? this.categories,
        fullPulledAt: fullPulledAt ?? this.fullPulledAt,
      );

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        if (name.isNotEmpty) 'name': name,
        if (transport.isNotEmpty) 'transport': transport,
        if (lastSeenAt > 0) 'lastSeenAt': lastSeenAt,
        if (lastSuccessAt > 0) 'lastSuccessAt': lastSuccessAt,
        if (lastPullAt > 0) 'lastPullAt': lastPullAt,
        if (lastPushAt > 0) 'lastPushAt': lastPushAt,
        if (lastError != null) 'lastError': lastError!.toJson(),
        if (behindBy != null) 'behindBy': behindBy,
        if (behindBytes != null) 'behindBytes': behindBytes,
        if (clockSkewMs != null) 'clockSkewMs': clockSkewMs,
        if (cursorSeq >= 0) 'cursorSeq': cursorSeq,
        if (ackedSeq >= 0) 'ackedSeq': ackedSeq,
        if (snapshotId.isNotEmpty) 'snapshotId': snapshotId,
        if (categories.isNotEmpty) 'categories': categories,
        if (fullPulledAt > 0) 'fullPulledAt': fullPulledAt,
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
      // 缺失 = 旧状态：0 让 effectiveLastSuccessAt 走兼容兜底。
      lastSuccessAt: (raw['lastSuccessAt'] as num?)?.toInt() ?? 0,
      lastPullAt: (raw['lastPullAt'] as num?)?.toInt() ?? 0,
      lastPushAt: (raw['lastPushAt'] as num?)?.toInt() ?? 0,
      lastError: SyncIssue.fromJson(raw['lastError']),
      behindBy: (raw['behindBy'] as num?)?.toInt(),
      behindBytes: (raw['behindBytes'] as num?)?.toInt(),
      clockSkewMs: (raw['clockSkewMs'] as num?)?.toInt(),
      cursorSeq: (raw['cursorSeq'] as num?)?.toInt() ?? -1,
      ackedSeq: (raw['ackedSeq'] as num?)?.toInt() ?? -1,
      snapshotId: raw['snapshotId'] as String? ?? '',
      categories:
          (raw['categories'] as List?)?.whereType<String>().toList() ?? const [],
      fullPulledAt: (raw['fullPulledAt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 一轮同步的结果对象（UI 状态与日志共用）。
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
