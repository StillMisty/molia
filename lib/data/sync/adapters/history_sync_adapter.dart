import '../../../domain/models/device_sync.dart';
import '../../../domain/ports/library_sync_store.dart';
import '../sync_adapter.dart';

/// 播放历史适配器（`play_history`）。
///
/// 合并键 = 平台 + 曲目 id（与表唯一键同构），时间戳 = `playedAt`；
/// 用户删除（单条 / 批量 / 清空）写墓碑，上限淘汰不写墓碑。
/// 只依赖同步面端口（[LibrarySyncStore]），不接触列名与行结构。
class HistorySyncAdapter implements SyncAdapter {
  HistorySyncAdapter({required LibrarySyncStore repository})
      : _repository = repository;

  final LibrarySyncStore _repository;

  @override
  Set<SyncCategory> get categories => const {SyncCategory.history};

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect() async {
    final records = <SyncRecord>[];
    for (final entry in await _repository.syncExportHistory()) {
      if (entry.sourceKey.isEmpty || entry.songId.isEmpty) continue;
      records.add(SyncRecord(
        key: SyncRecordKeys.history(entry.sourceKey, entry.songId),
        updatedAt: entry.playedAt,
        data: entry.toJson(),
      ));
    }
    for (final tombstone in await _repository.syncExportTombstones(
      [SyncCategory.history.name],
    )) {
      records.add(SyncRecord.tombstone(
        key: tombstone.key,
        updatedAt: tombstone.updatedAt,
        updatedBy: tombstone.updatedBy,
      ));
    }
    return {SyncCategory.history: records};
  }

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async {
    final entries = <PlayHistorySyncRecord>[];
    final tombstones = <SyncTombstoneRecord>[];
    for (final record
        in records[SyncCategory.history] ?? const <SyncRecord>[]) {
      if (record.deleted) {
        tombstones.add(SyncTombstoneRecord(
          category: SyncCategory.history.name,
          key: record.key,
          updatedAt: record.updatedAt,
          updatedBy: record.updatedBy,
        ));
      } else {
        entries.add(PlayHistorySyncRecord.fromJson(
          record.data ?? const <String, Object?>{},
        ));
      }
    }
    if (entries.isEmpty && tombstones.isEmpty) return SyncApplyOutcome.none;
    final result = await _repository.syncApplyHistory(
      entries: entries,
      tombstones: tombstones,
    );
    return SyncApplyOutcome(applied: result.applied, skipped: result.skipped);
  }
}
