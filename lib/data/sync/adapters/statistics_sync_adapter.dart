import '../../../domain/models/device_sync.dart';
import '../../play_statistics_repository.dart';
import '../sync_adapter.dart';

/// 听歌统计适配器：`play_events` 已收尾事件的逐条合并。
///
/// append-only 语义：记录键 = `syncKey`（跨设备去重的唯一键），时间戳取
/// `endedAt`（同键覆盖只可能来自「先同步了中途收尾的事件、之后才真正
/// 收尾」的场景）。删除不参与同步。
class StatisticsSyncAdapter implements SyncAdapter {
  StatisticsSyncAdapter({required PlayStatisticsRepository repository})
      : _repository = repository;

  final PlayStatisticsRepository _repository;

  @override
  Set<SyncCategory> get categories => const {SyncCategory.statistics};

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect() async {
    final events = await _repository.syncExportEvents();
    return {
      SyncCategory.statistics: [
        for (final event in events)
          if ((event['syncKey'] as String?)?.isNotEmpty ?? false)
            SyncRecord(
              key: event['syncKey'] as String,
              updatedAt: (event['endedAt'] as num?)?.toInt() ?? 0,
              updatedBy: event['originDeviceId'] as String? ?? '',
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
      events.add({
        ...record.data!,
        'syncKey': record.key,
        'endedAt': (record.data!['endedAt'] as num?)?.toInt() ?? record.updatedAt,
      });
    }
    final result = await _repository.syncApplyEvents(events);
    return SyncApplyOutcome(
      applied: result.applied,
      skipped: result.skipped + skipped,
    );
  }
}
