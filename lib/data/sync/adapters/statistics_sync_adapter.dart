import '../../../domain/models/device_sync.dart';
import '../../../domain/ports/statistics_sync_store.dart';
import '../sync_adapter.dart';

/// 听歌统计适配器：类型化事件 ↔ `SyncRecord` 的薄映射。
///
/// 导出缓存 / 指纹、存量键回填、本地下载曲目过滤与按 `syncKey` 合并都在
/// [StatisticsSyncStore] 里；适配器不再认识 `play_events` 的列，也不再直接
/// 依赖统计仓库。
///
/// append-only 语义：记录键 = `syncKey`（跨设备去重的唯一键），版本 =
/// 发号器给的三元组（收尾时取号）；`endedAt`（何时结束）是内容时间、
/// **不参与胜负判定**。删除不参与同步。
class StatisticsSyncAdapter implements SyncAdapter {
  StatisticsSyncAdapter({required StatisticsSyncStore store}) : _store = store;

  final StatisticsSyncStore _store;

  /// 上轮记录缓存：键 = 导出变更的廉价指纹。
  String? _cacheKey;
  Map<SyncCategory, List<SyncRecord>>? _cached;

  @override
  Set<SyncCategory> get categories => const {SyncCategory.statistics};

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect(
      {bool fresh = false}) async {
    final key = await _store.syncFingerprint();
    final cached = _cached;
    if (!fresh && cached != null && _cacheKey == key) return cached;
    final records = await _readRecords();
    _cacheKey = key;
    _cached = records;
    return records;
  }

  Future<Map<SyncCategory, List<SyncRecord>>> _readRecords() async {
    final events = await _store.syncExportEvents();
    return {
      SyncCategory.statistics: [
        for (final event in events)
          SyncRecord(
            key: event.syncKey,
            version: event.version,
            data: event.toData(),
          ),
      ],
    };
  }

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async {
    final events = <StatisticsSyncEvent>[];
    var skipped = 0;
    for (final record
        in records[SyncCategory.statistics] ?? const <SyncRecord>[]) {
      if (record.deleted || record.data == null) {
        skipped++;
        continue;
      }
      // 信封的键 / 版本是权威来源；data 里的版本列只用于自包含备份解析。
      final event = StatisticsSyncEvent.fromData(
        key: record.key,
        version: record.version,
        data: record.data!,
      );
      if (event == null) {
        skipped++;
        continue;
      }
      events.add(event);
    }
    final result = await _store.syncApplyEvents(events);
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
