import '../../../domain/models/device_sync.dart';
import '../../../domain/models/download.dart' show kLocalSourceKey;
import '../../../domain/ports/library_sync_store.dart';
import '../sync_adapter.dart';

/// 播放历史适配器（`play_history`）。
///
/// 合并键 = 平台 + 曲目 id（与表唯一键同构）；版本 = 发号器给的三元组，
/// `playedAt`（何时听的）是内容时间、**不参与胜负判定**；删除墓碑另带真实
/// 删除时间（`deletedAt`），「删除 vs 播放」由库内按真实时间判定。
/// 用户删除（单条 / 批量 / 清空）写墓碑，上限淘汰不写墓碑。
/// 只依赖同步面端口（[LibrarySyncStore]），不接触列名与行结构。
///
/// 本地下载曲目（`sourceKey = local`）不同步：文件是设备本机的持久副本，
/// 导出与应用两侧都过滤（含其墓碑）。
class HistorySyncAdapter implements SyncAdapter {
  HistorySyncAdapter({required LibrarySyncStore repository})
      : _repository = repository;

  final LibrarySyncStore _repository;

  /// 上轮记录缓存：键 = 类别指纹（`COUNT(*) + MAX(versionPhysical)` 聚合）。
  String? _cacheKey;
  Map<SyncCategory, List<SyncRecord>>? _cached;

  @override
  Set<SyncCategory> get categories => const {SyncCategory.history};

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect({bool fresh = false}) async {
    final key = syncFingerprintKey(
      await _repository.syncFingerprints(categories),
    );
    final cached = _cached;
    if (!fresh && cached != null && _cacheKey == key) return cached;
    final records = await _readRecords();
    _cacheKey = key;
    _cached = records;
    return records;
  }

  Future<Map<SyncCategory, List<SyncRecord>>> _readRecords() async {
    final records = <SyncRecord>[];
    for (final entry in await _repository.syncExportHistory()) {
      if (entry.sourceKey.isEmpty || entry.songId.isEmpty) continue;
      // 本地下载曲目不同步（文件是设备本机的持久副本）。
      if (entry.sourceKey == kLocalSourceKey) continue;
      records.add(SyncRecord(
        key: SyncRecordKeys.history(entry.sourceKey, entry.songId),
        version: entry.version,
        data: entry.toJson(),
      ));
    }
    for (final tombstone in await _repository.syncExportTombstones(
      [SyncCategory.history.name],
    )) {
      // 本地下载曲目的墓碑同样不同步。
      final parsed = SyncRecordKeys.parseHistory(tombstone.key);
      if (parsed != null && parsed.sourceKey == kLocalSourceKey) continue;
      records.add(SyncRecord.tombstone(
        key: tombstone.key,
        version: tombstone.version,
        deletedAt: tombstone.deletedAt,
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
        final parsed = SyncRecordKeys.parseHistory(record.key);
        if (parsed != null && parsed.sourceKey == kLocalSourceKey) continue;
        tombstones.add(SyncTombstoneRecord(
          category: SyncCategory.history.name,
          key: record.key,
          version: record.version,
          deletedAt: record.deletedAt,
        ));
      } else {
        final entry = PlayHistorySyncRecord.fromJson(
          record.data ?? const <String, Object?>{},
          version: record.version,
        );
        if (entry.sourceKey == kLocalSourceKey) continue;
        entries.add(entry);
      }
    }
    if (entries.isEmpty && tombstones.isEmpty) return SyncApplyOutcome.none;
    final result = await _repository.syncApplyHistory(
      entries: entries,
      tombstones: tombstones,
    );
    // 落地了远端记录：远端版本可能小于本机最大值，缓存显式失效。
    if (result.applied > 0) {
      _cacheKey = null;
      _cached = null;
    }
    return SyncApplyOutcome(applied: result.applied, skipped: result.skipped);
  }
}
