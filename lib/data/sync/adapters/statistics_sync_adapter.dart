import '../../../domain/models/device_sync.dart';
import '../../../domain/models/download.dart' show kLocalSourceKey;
import '../../play_statistics_repository.dart';
import '../sync_adapter.dart';

/// 听歌统计适配器：`play_events` 已收尾事件的逐条合并。
///
/// append-only 语义：记录键 = `syncKey`（跨设备去重的唯一键），版本 =
/// 发号器给的三元组（收尾时取号）；`endedAt`（何时结束）是内容时间、
/// **不参与胜负判定**——同键覆盖只可能来自「先同步了中途收尾的事件、
/// 之后才真正收尾」的场景，按版本取新。删除不参与同步。
///
/// 本地下载曲目（`sourceKey = local`）的事件不同步：文件是设备本机的持久
/// 副本，其它设备无法复现该曲目；本机统计不受影响。
class StatisticsSyncAdapter implements SyncAdapter {
  StatisticsSyncAdapter({required PlayStatisticsRepository repository})
      : _repository = repository;

  final PlayStatisticsRepository _repository;

  /// 上轮记录缓存：键 = 已收尾事件的廉价指纹。
  String? _cacheKey;
  Map<SyncCategory, List<SyncRecord>>? _cached;

  @override
  Set<SyncCategory> get categories => const {SyncCategory.statistics};

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect({bool fresh = false}) async {
    final key = await _repository.syncFingerprint();
    final cached = _cached;
    if (!fresh && cached != null && _cacheKey == key) return cached;
    final records = await _readRecords();
    _cacheKey = key;
    _cached = records;
    return records;
  }

  Future<Map<SyncCategory, List<SyncRecord>>> _readRecords() async {
    final events = await _repository.syncExportEvents();
    return {
      SyncCategory.statistics: [
        for (final event in events)
          if (event['sourceKey'] != kLocalSourceKey &&
              ((event['syncKey'] as String?)?.isNotEmpty ?? false))
            SyncRecord(
              key: event['syncKey'] as String,
              version: SyncVersion(
                physical: (event['versionPhysical'] as num?)?.toInt() ?? 0,
                counter: (event['versionCounter'] as num?)?.toInt() ?? 0,
                deviceId: event['originDeviceId'] as String? ?? '',
              ),
              data: {
                for (final entry in event.entries)
                  if (entry.key != 'id') entry.key: entry.value,
              },
            ),
      ],
    };
  }

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async {
    final events = <Map<String, Object?>>[];
    var skipped = 0;
    for (final record
        in records[SyncCategory.statistics] ?? const <SyncRecord>[]) {
      if (record.deleted || record.data == null) {
        skipped++;
        continue;
      }
      // 本地下载曲目的事件不落地（对端文件在本机不存在）。
      if (record.data!['sourceKey'] == kLocalSourceKey) {
        skipped++;
        continue;
      }
      // 版本以记录信封为准（data 里的版本列只用于自包含备份文件）。
      events.add({
        ...record.data!,
        'syncKey': record.key,
        'versionPhysical': record.version.physical,
        'versionCounter': record.version.counter,
        'originDeviceId': record.version.deviceId,
      });
    }
    final result = await _repository.syncApplyEvents(events);
    // 落地了远端事件：远端版本可能小于本机最大值，缓存显式失效。
    if (result.applied > 0) {
      _cacheKey = null;
      _cached = null;
    }
    return SyncApplyOutcome(
      applied: result.applied,
      skipped: result.skipped + skipped,
    );
  }
}
