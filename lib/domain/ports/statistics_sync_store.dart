import '../models/device_sync.dart';
import '../models/download.dart' show kLocalSourceKey;

/// 一条可同步的已收尾播放事件（类型化）。
///
/// 适配器只认识本类型：SQL 列名、行结构与旧键回填都留在
/// `StatisticsSyncStore` 的实现里。`syncKey` 是跨设备去重键，[version] 是
/// 唯一的胜负判据；`startedAt` / `endedAt` 只是内容时间，不参与 LWW。
///
/// [toData] 保持 v5 之前的线上形状（事件字段 + 曲目内容逐条自包含），
/// 这样旧对端仍能解析；`id` / `trackId` 是本机行标识，永不出本机。
class StatisticsSyncEvent {
  const StatisticsSyncEvent({
    required this.syncKey,
    required this.version,
    required this.sourceKey,
    required this.songId,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.coverUrl,
    this.durationMs,
    this.raw = '',
    required this.startedAt,
    this.endedAt,
    this.listenedMs = 0,
    this.maxPositionMs = 0,
    this.endReason,
  });

  /// 跨设备去重键（收尾时分配，存量行由内容哈希回填）。
  final String syncKey;

  /// 版本三元组（收尾时由发号器取号；原地更新时比较）。
  final SyncVersion version;

  final String sourceKey;
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? durationMs;

  /// 平台原始对象（JSON 文本；空串 = 无载荷）。
  final String raw;

  final int startedAt;

  /// 何时结束（内容时间；null = 损坏或进行中记录，应用时跳过）。
  final int? endedAt;

  final int listenedMs;
  final int maxPositionMs;
  final String? endReason;

  /// 本地下载曲目（`sourceKey = local`）的事件不同步：文件是设备本机的
  /// 持久副本，其它设备无法复现该曲目；本机统计不受影响。
  ///
  /// 过滤放在 store（导出与应用两侧统一做），适配器不需要知道这个业务规则。
  bool get isLocal => sourceKey == kLocalSourceKey;

  /// 复制并替换载荷：导出缓存按曲共享同一份 JSON 字符串，避免逐事件复制。
  StatisticsSyncEvent withRaw(String value) => StatisticsSyncEvent(
        syncKey: syncKey,
        version: version,
        sourceKey: sourceKey,
        songId: songId,
        title: title,
        artist: artist,
        album: album,
        coverUrl: coverUrl,
        durationMs: durationMs,
        raw: value,
        startedAt: startedAt,
        endedAt: endedAt,
        listenedMs: listenedMs,
        maxPositionMs: maxPositionMs,
        endReason: endReason,
      );

  /// 线上载荷（与 v5 之前的行结构同键名；记录逐条自包含）。
  ///
  /// 版本列也保留在 data 里：备份文件按自包含记录解析时仍需版本；
  /// 正常同步以记录信封的 [version] 为准。
  Map<String, Object?> toData() => {
        'syncKey': syncKey,
        'originDeviceId': version.deviceId,
        'versionPhysical': version.physical,
        'versionCounter': version.counter,
        'startedAt': startedAt,
        'endedAt': endedAt,
        'listenedMs': listenedMs,
        'maxPositionMs': maxPositionMs,
        'endReason': endReason,
        'sourceKey': sourceKey,
        'songId': songId,
        'title': title,
        'artist': artist,
        'album': album,
        'coverUrl': coverUrl,
        'durationMs': durationMs,
        'raw': raw,
      };

  /// 从同步记录载荷解析；缺去重键 / 结束时间返回 null（调用方计入 skipped）。
  ///
  /// [key] 与 [version] 来自记录信封（权威来源）；data 内的版本列只用于
  /// 自包含备份文件，这里不读取。
  static StatisticsSyncEvent? fromData({
    required String key,
    required SyncVersion version,
    required Map<String, Object?> data,
  }) {
    final endedAt = (data['endedAt'] as num?)?.toInt();
    if (key.isEmpty || endedAt == null) return null;
    return StatisticsSyncEvent(
      syncKey: key,
      version: version,
      sourceKey: data['sourceKey'] as String? ?? '',
      songId: data['songId'] as String? ?? '',
      title: data['title'] as String? ?? '',
      artist: data['artist'] as String? ?? '',
      album: data['album'] as String? ?? '',
      coverUrl: data['coverUrl'] as String?,
      durationMs: (data['durationMs'] as num?)?.toInt(),
      raw: data['raw'] as String? ?? '',
      startedAt: (data['startedAt'] as num?)?.toInt() ?? 0,
      endedAt: endedAt,
      listenedMs: (data['listenedMs'] as num?)?.toInt() ?? 0,
      maxPositionMs: (data['maxPositionMs'] as num?)?.toInt() ?? 0,
      endReason: data['endReason'] as String?,
    );
  }
}

/// 听歌统计的同步面端口：类型化记录出 / 入。
///
/// 统计仓库只负责事件采集与查询；导出缓存、存量键回填、本地曲目过滤与
/// 按 `syncKey` 合并都收在实现里。适配器只做「类型化记录 ↔ SyncRecord」，
/// 不再接触列名与版本列。
abstract interface class StatisticsSyncStore {
  /// 导出变更的廉价指纹（导出内容只可能在少数写入点变化）。
  Future<String> syncFingerprint();

  /// 全部已收尾且可同步的事件（已过滤本地下载曲目）。
  Future<List<StatisticsSyncEvent>> syncExportEvents();

  /// 按 `syncKey` 去重合并远端事件（单事务、幂等）。
  Future<({int applied, int skipped})> syncApplyEvents(
    List<StatisticsSyncEvent> events,
  );
}
