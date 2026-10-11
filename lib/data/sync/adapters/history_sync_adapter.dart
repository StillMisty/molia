import '../../../domain/models/device_sync.dart';
import '../../library_repository.dart';
import '../sync_adapter.dart';

/// 播放历史适配器（`play_history`）。
///
/// 合并键 = 平台 + 曲目 id（与表唯一键同构），时间戳 = `playedAt`；
/// 用户删除（单条 / 批量 / 清空）写墓碑，上限淘汰不写墓碑。
class HistorySyncAdapter implements SyncAdapter {
  HistorySyncAdapter({required LibraryRepository repository})
      : _repository = repository;

  final LibraryRepository _repository;

  @override
  Set<SyncCategory> get categories => const {SyncCategory.history};

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect() async {
    final records = <SyncRecord>[];
    for (final row in await _repository.syncExportHistory()) {
      final sourceKey = row['sourceKey'] as String? ?? '';
      final songId = row['songId'] as String? ?? '';
      if (sourceKey.isEmpty || songId.isEmpty) continue;
      records.add(SyncRecord(
        key: SyncRecordKeys.history(sourceKey, songId),
        updatedAt: (row['playedAt'] as num?)?.toInt() ?? 0,
        data: {
          'sourceKey': sourceKey,
          'songId': songId,
          'title': row['title'] as String? ?? '',
          'artist': row['artist'] as String? ?? '',
          'album': row['album'] as String? ?? '',
          'coverUrl': row['coverUrl'] as String?,
          'durationMs': (row['durationMs'] as num?)?.toInt(),
          'raw': row['raw'] as String? ?? '{}',
          'playedAt': (row['playedAt'] as num?)?.toInt() ?? 0,
        },
      ));
    }
    for (final row in await _repository.syncExportTombstones(
      [SyncCategory.history.name],
    )) {
      records.add(SyncRecord.tombstone(
        key: row['key'] as String? ?? '',
        updatedAt: (row['updatedAt'] as num?)?.toInt() ?? 0,
        updatedBy: row['updatedBy'] as String? ?? '',
      ));
    }
    return {SyncCategory.history: records};
  }

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async {
    final entries = <Map<String, Object?>>[];
    final tombstones = <Map<String, Object?>>[];
    for (final record
        in records[SyncCategory.history] ?? const <SyncRecord>[]) {
      if (record.deleted) {
        tombstones.add({
          'category': SyncCategory.history.name,
          'key': record.key,
          'updatedAt': record.updatedAt,
          'updatedBy': record.updatedBy,
        });
      } else {
        entries.add(record.data ?? const <String, Object?>{});
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
