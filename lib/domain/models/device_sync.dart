/// 跨设备数据同步的纯领域模型：记录 / 快照 / 合并规则。
///
/// 同步模型是「全量合并」：每台设备持有自己已知的完整视图（每条记录带
/// `updatedAt` + `updatedBy`，删除用墓碑记录表达），设备间交换视图后逐键
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

/// 一条同步记录。删除 = `deleted` 为 true 的墓碑（`data` 为 null）。
class SyncRecord {
  final String key;
  final bool deleted;

  /// 墙上时钟毫秒（设备本地时钟；时钟不可信时由 [updatedBy] 决平局）。
  final int updatedAt;

  /// 产生该记录的设备 id；空串表示未知来源。
  final String updatedBy;

  /// 类别载荷（JSON 友好；墓碑为 null）。
  final Map<String, Object?>? data;

  const SyncRecord({
    required this.key,
    required this.updatedAt,
    this.deleted = false,
    this.updatedBy = '',
    this.data,
  });

  static SyncRecord tombstone({
    required String key,
    required int updatedAt,
    String updatedBy = '',
  }) =>
      SyncRecord(key: key, updatedAt: updatedAt, deleted: true, updatedBy: updatedBy);

  /// [this] 是否严格新于 [other]（`(updatedAt, updatedBy)` 字典序）。
  bool isNewerThan(SyncRecord other) {
    if (updatedAt != other.updatedAt) return updatedAt > other.updatedAt;
    return updatedBy.compareTo(other.updatedBy) > 0;
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        if (deleted) 'deleted': true,
        'updatedAt': updatedAt,
        if (updatedBy.isNotEmpty) 'updatedBy': updatedBy,
        if (data != null) 'data': data,
      };

  /// 宽容解析：缺 key 等必填字段返回 null（坏记录跳过而不是整体失败）。
  static SyncRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    final updatedAt = raw['updatedAt'];
    if (key is! String || key.isEmpty || updatedAt is! num) return null;
    final data = raw['data'];
    return SyncRecord(
      key: key,
      deleted: raw['deleted'] == true,
      updatedAt: updatedAt.toInt(),
      updatedBy: raw['updatedBy'] is String ? raw['updatedBy'] as String : '',
      data: data is Map
          ? data.map((k, v) => MapEntry(k.toString(), v as Object?))
          : null,
    );
  }

  @override
  String toString() => 'SyncRecord($key, t=$updatedAt, d=$deleted)';
}

/// 一次同步快照：设备身份 + 各类别记录。
class SyncEnvelope {
  /// 协议版本（解析到未知版本的新字段时忽略而不失败）。
  static const int protocolVersion = 1;

  final String deviceId;
  final String deviceName;
  final int producedAt;
  final Map<SyncCategory, List<SyncRecord>> records;

  const SyncEnvelope({
    required this.deviceId,
    this.deviceName = '',
    required this.producedAt,
    this.records = const {},
  });

  Iterable<SyncRecord> recordsOf(SyncCategory category) =>
      records[category] ?? const [];

  int get recordCount =>
      records.values.fold(0, (sum, list) => sum + list.length);

  /// 生成推送用快照：丢弃 [tombstoneRetentionMs] 之前的墓碑
  /// （墓碑长期保留会撑大快照；保留期外复活风险由保留期覆盖）。
  SyncEnvelope pruneTombstones({
    required int now,
    required int tombstoneRetentionMs,
  }) {
    final pruned = <SyncCategory, List<SyncRecord>>{};
    for (final entry in records.entries) {
      final kept = [
        for (final record in entry.value)
          if (!(record.deleted &&
              now - record.updatedAt > tombstoneRetentionMs))
            record,
      ];
      if (kept.isNotEmpty) pruned[entry.key] = kept;
    }
    return SyncEnvelope(
      deviceId: deviceId,
      deviceName: deviceName,
      producedAt: producedAt,
      records: pruned,
    );
  }

  Map<String, dynamic> toJson() => {
        'v': protocolVersion,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'producedAt': producedAt,
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
      records: records,
    );
  }
}

/// 逐键取新：同一 key 保留 `(updatedAt, updatedBy)` 最大者；元组相等时
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

/// 一次同步轮次的结果（日志与 UI 状态用）。
class SyncReport {
  final bool ok;

  /// 收到的远端快照数（含空快照 / 解密失败的计入 `failedPulls`）。
  final int pulled;

  final int failedPulls;

  /// 实际落地的记录数（本地不存在或远端更新）。
  final int applied;

  /// 未采纳的记录数（本地已是更新版本）。
  final int skipped;

  final String? error;

  const SyncReport({
    required this.ok,
    this.pulled = 0,
    this.failedPulls = 0,
    this.applied = 0,
    this.skipped = 0,
    this.error,
  });

  static const SyncReport idle = SyncReport(ok: true);

  SyncReport copyWith({int? pulled, int? failedPulls, int? applied, int? skipped}) =>
      SyncReport(
        ok: ok,
        pulled: pulled ?? this.pulled,
        failedPulls: failedPulls ?? this.failedPulls,
        applied: applied ?? this.applied,
        skipped: skipped ?? this.skipped,
        error: error,
      );

  @override
  String toString() =>
      'SyncReport(ok=$ok, pulled=$pulled, applied=$applied, skipped=$skipped)';
}

/// 列表头同步记录（自增 id 不出本机；`syncId` 跨设备稳定，收藏为固定常量）。
///
/// 与 `syncExportPlaylists` / `syncApplyLibrary` 的 JSON 形状一一对应；
/// 列名 / 行结构只存在于资料库实现内部。
class PlaylistSyncRecord {
  const PlaylistSyncRecord({
    required this.syncId,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.updatedBy,
  });

  final String syncId;
  final String name;
  final int createdAt;
  final int updatedAt;
  final String updatedBy;

  Map<String, Object?> toJson() => {
        'syncId': syncId,
        'name': name,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'updatedBy': updatedBy,
      };

  /// 宽容解析：缺失 / 类型不符按空值处理（由应用侧按需跳过并计数）。
  static PlaylistSyncRecord fromJson(Map<String, Object?> data) =>
      PlaylistSyncRecord(
        syncId: data['syncId'] as String? ?? '',
        name: data['name'] as String? ?? '',
        createdAt: (data['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (data['updatedAt'] as num?)?.toInt() ?? 0,
        updatedBy: data['updatedBy'] as String? ?? '',
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
    required this.updatedAt,
    required this.updatedBy,
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
  final int updatedAt;
  final String updatedBy;

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
        'updatedAt': updatedAt,
        'updatedBy': updatedBy,
      };

  static PlaylistTrackSyncRecord fromJson(Map<String, Object?> data) =>
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
        updatedAt: (data['updatedAt'] as num?)?.toInt() ?? 0,
        updatedBy: data['updatedBy'] as String? ?? '',
      );
}

/// 播放历史同步记录（时间戳 = `playedAt`）。
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
  });

  final String sourceKey;
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? durationMs;
  final String raw;
  final int playedAt;

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
      };

  static PlayHistorySyncRecord fromJson(Map<String, Object?> data) =>
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
      );
}

/// 资料库墓碑记录（删除也取新：`category + key` + 时间戳）。
class SyncTombstoneRecord {
  const SyncTombstoneRecord({
    required this.category,
    required this.key,
    required this.updatedAt,
    required this.updatedBy,
  });

  final String category;
  final String key;
  final int updatedAt;
  final String updatedBy;

  Map<String, Object?> toJson() => {
        'category': category,
        'key': key,
        'updatedAt': updatedAt,
        'updatedBy': updatedBy,
      };

  static SyncTombstoneRecord fromJson(Map<String, Object?> data) =>
      SyncTombstoneRecord(
        category: data['category'] as String? ?? '',
        key: data['key'] as String? ?? '',
        updatedAt: (data['updatedAt'] as num?)?.toInt() ?? 0,
        updatedBy: data['updatedBy'] as String? ?? '',
      );
}
