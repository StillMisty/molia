import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../domain/models/device_sync.dart';
import '../../../services/ai/ai_recommendation_store.dart';
import '../sync_adapter.dart';
import '../sync_book.dart';
import '../sync_journal.dart';
import '../sync_stamp.dart';

/// AI 推荐历史适配器（`aiDj` 类别）。
///
/// - 记录键 = 批次 id；批次 JSON 不含 LLM 原始返回与提示词（只存内存），
///   含曲目原始 payload，因此单批可达数百 KB、按大类别处理（蜂窝小类别轮
///   不收集）；
/// - 版本 = 内容哈希变化时向发号器现取的版本戳；登记在同步状态里跨轮稳定；
/// - active 指针作为单例记录（[SyncRecordKeys.activeAiBatchKey]），首次为空
///   用零值戳，避免新设备加入时用自己的「空 active」清掉对端；
/// - 删除（本地保留策略 / 用户删除 / 清空）登记墓碑并传播；远端墓碑只删
///   对应批次，不改其它历史；
/// - 远端应用经 [AiRecommendationStore.applySyncedHistory] 一次写索引，并
///   回调 [onApplied] 让 Provider 重读内存索引（不触发本地变更，避免回环）。
class AiDjSyncAdapter implements CategoryScopedSyncAdapter {
  AiDjSyncAdapter({
    required this._store,
    required this._state,
    this._journal,
    this._onApplied,
  });

  final AiRecommendationStore _store;
  final SyncStampLedger _state;

  /// 增量日志（可选）：本地变化在 collect 时补写，让已连接的对端不必等
  /// 全量快照。
  final SyncJournalAppender? _journal;
  final Future<void> Function()? _onApplied;

  @override
  Set<SyncCategory> get categories => const {SyncCategory.aiDj};

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect({bool fresh = false}) =>
      collectForCategories(categories, fresh: fresh);

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collectForCategories(
    Set<SyncCategory> categories, {
    bool fresh = false,
  }) async {
    if (!categories.contains(SyncCategory.aiDj)) return const {};
    final index = await _store.loadIndex();
    final indexIds = {for (final entry in index.entries) entry.id};
    final current = <String, ({StoredAiBatch batch, String hash})>{};
    for (final entry in index.entries) {
      final batch = await _store.loadBatch(entry.id);
      // 索引有条目但载荷读失败不算删除：瞬时 IO 失败不能把对端的历史也删掉。
      if (batch == null) continue;
      current[entry.id] = (batch: batch, hash: _hashOf(batch));
    }

    final changes = <SyncJournalChange>[];
    final registrations = <String, SyncStamp>{};
    final removedStamps = <String>{};
    final removedTombstones = <String>{};
    final newTombstones = <String, SyncStamp>{};
    final records = <SyncRecord>[];

    // 上轮登记过、本轮索引里也没有 = 本地删除（含保留策略裁剪）。
    for (final id in _state.aiBatchStamps.keys.toList()) {
      if (indexIds.contains(id)) continue;
      final version = _state.stampIssuer.next();
      newTombstones[id] = SyncStamp(version: version);
      removedStamps.add(id);
      changes.add((
        category: SyncCategory.aiDj,
        record: SyncRecord.tombstone(
          key: id,
          version: version,
          deletedAt: version.physical,
        ),
      ));
    }

    for (final entry in current.entries) {
      final id = entry.key;
      final stamp = _state.aiBatchStamps[id];
      final tombstone = _state.aiBatchTombstones[id];
      final unchanged =
          tombstone == null && stamp != null && stamp.hash == entry.value.hash;
      final version = unchanged ? stamp.version : _state.stampIssuer.next();
      if (!unchanged) {
        registrations[id] = SyncStamp(hash: entry.value.hash, version: version);
      }
      if (tombstone != null) removedTombstones.add(id);
      final record = SyncRecord(
        key: id,
        version: version,
        data: entry.value.batch.toJson(),
      );
      records.add(record);
      if (!unchanged) {
        changes.add((category: SyncCategory.aiDj, record: record));
      }
    }

    // 仍然生效的墓碑（当前索引里没有同名批次）。
    for (final entry in {
      ..._state.aiBatchTombstones,
      ...newTombstones,
    }.entries) {
      if (indexIds.contains(entry.key)) continue;
      records.add(
        SyncRecord.tombstone(
          key: entry.key,
          version: entry.value.version,
          deletedAt: entry.value.version.physical,
        ),
      );
    }

    // active 指针：首次为空用零值戳（新设备不能用自己的空值压掉对端）。
    final activeId = index.activeBatchId;
    final activeHash = activeId ?? '';
    final storedActive = _state.activeAiBatchStamp;
    final SyncStamp effectiveActive;
    var activeChanged = false;
    if (storedActive == null) {
      if (activeId == null) {
        effectiveActive = SyncStamp(hash: '', version: SyncVersion.zero);
      } else {
        effectiveActive = SyncStamp(
          hash: activeHash,
          version: _state.stampIssuer.next(),
        );
        activeChanged = true;
      }
    } else if (storedActive.hash != activeHash) {
      effectiveActive = SyncStamp(
        hash: activeHash,
        version: _state.stampIssuer.next(),
      );
      activeChanged = true;
    } else {
      effectiveActive = storedActive;
    }
    final activeRecord = SyncRecord(
      key: SyncRecordKeys.activeAiBatchKey,
      version: effectiveActive.version,
      data: {'id': activeId},
    );
    records.add(activeRecord);
    if (activeChanged) {
      changes.add((category: SyncCategory.aiDj, record: activeRecord));
    }

    // 先追加日志、后写登记：追加失败时保留旧登记，下一轮仍能检测到变更。
    final journal = _journal;
    if (journal != null && changes.isNotEmpty) {
      await journal.appendAll(changes);
    }
    for (final id in removedStamps) {
      _state.removeAiBatchStamp(id);
    }
    for (final id in removedTombstones) {
      _state.removeAiBatchTombstone(id);
    }
    for (final entry in registrations.entries) {
      _state.putAiBatchStamp(entry.key, entry.value);
    }
    for (final entry in newTombstones.entries) {
      _state.putAiBatchTombstone(entry.key, entry.value);
    }
    if (storedActive == null ||
        storedActive.hash != effectiveActive.hash ||
        storedActive.version != effectiveActive.version) {
      _state.setActiveAiBatchStamp(effectiveActive);
    }
    return {SyncCategory.aiDj: records};
  }

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async {
    final list = records[SyncCategory.aiDj] ?? const <SyncRecord>[];
    if (list.isEmpty) return SyncApplyOutcome.none;

    final batches = <StoredAiBatch>[];
    final batchStamps = <String, SyncStamp>{};
    final deleted = <String>{};
    final tombstones = <String, SyncStamp>{};
    var activeSpecified = false;
    var skipped = 0;
    String? activeId;
    SyncStamp? activeStamp;

    for (final record in list) {
      if (record.key == SyncRecordKeys.activeAiBatchKey) {
        activeSpecified = true;
        final raw = record.deleted ? null : record.data?['id']?.toString();
        activeId = raw == null || raw.isEmpty ? null : raw;
        activeStamp = SyncStamp(hash: activeId ?? '', version: record.version);
        continue;
      }
      if (record.deleted) {
        deleted.add(record.key);
        tombstones[record.key] = SyncStamp(version: record.version);
        continue;
      }
      final batch = StoredAiBatch.fromJson(record.data);
      if (batch == null || batch.id.isEmpty || batch.id != record.key) {
        skipped++;
        continue;
      }
      batches.add(batch);
      batchStamps[batch.id] = SyncStamp(
        hash: _hashOf(batch),
        version: record.version,
      );
    }

    if (batches.isEmpty && deleted.isEmpty && !activeSpecified) {
      return SyncApplyOutcome(skipped: skipped);
    }

    final result = await _store.applySyncedHistory(
      batches: batches,
      deletedIds: deleted,
      activeSpecified: activeSpecified,
      activeBatchId: activeId,
    );
    if (!result.ok) {
      // 写回失败要让轮次把入站快照放回队列重试，不能登记成「已应用」。
      throw StateError('AI 推荐历史写回失败');
    }

    for (final id in deleted) {
      _state.removeAiBatchStamp(id);
      final stamp = tombstones[id];
      if (stamp != null) _state.putAiBatchTombstone(id, stamp);
    }
    for (final entry in batchStamps.entries) {
      _state.putAiBatchStamp(entry.key, entry.value);
      _state.removeAiBatchTombstone(entry.key);
    }
    if (activeSpecified && activeStamp != null) {
      // 登记最终 active：远端指向未落地批次时会落到 null，下一轮 collect
      // 用新版本把这个纠正发回去。
      _state.setActiveAiBatchStamp(
        SyncStamp(
          hash: result.activeBatchId ?? '',
          version: activeStamp.version,
        ),
      );
    }
    try {
      await _onApplied?.call();
    } catch (_) {
      // 重载失败只影响本机 UI 新鲜度，不能把已落地的记录变成失败。
    }
    return SyncApplyOutcome(
      applied: batches.length + deleted.length + (activeSpecified ? 1 : 0),
      skipped: skipped,
    );
  }

  static String _hashOf(StoredAiBatch batch) =>
      sha1.convert(utf8.encode(jsonEncode(batch.toJson()))).toString();
}
