/// 行表类适配器的变化检测装饰器：指纹缓存 / fresh 绕过 / 落地后失效。
///
/// 为什么装饰而不是让每个适配器各写一份：歌单 / 历史 / 统计共用同一段缓存
/// 逻辑（读廉价指纹 → 未变复用上轮记录 → apply 落地后显式失效），各写一份
/// 容易在「fresh 绕过」或「远端版本小于本机最大值时指纹不变」这类边界上
/// 漂移。缓存是同步层的成本优化，不是适配器自己的业务，因此适配器
/// 只剩 [SyncRecordSource.exportRecords] / [SyncRecordSource.apply]。
///
/// 版本戳 / 增量日志**不**上移到装饰器：行表的取号与日志追加必须在数据写入
/// 的同一事务里完成（ADR-0003 §5），由库内写入点负责；装饰器只拥有可以由
/// 存储重新导出的派生缓存。
library;

import '../../../domain/models/device_sync.dart';
import '../sync_adapter.dart';

/// 廉价指纹读取：同一份存储状态返回同一字符串（不改动数据）。
typedef SyncFingerprintReader = Future<String> Function();

/// 把纯记录源包装成同步适配器，并统一拥有上轮记录缓存。
class ChangeDetectingAdapter implements SyncAdapter, SyncAdapterCacheReleaser {
  ChangeDetectingAdapter({
    required SyncRecordSource source,
    required SyncFingerprintReader fingerprint,
  }) : _sourceAdapter = source,
       _fingerprintReader = fingerprint;

  final SyncRecordSource _sourceAdapter;
  final SyncFingerprintReader _fingerprintReader;

  /// 上轮记录缓存：键 = 类别指纹（由数据层提供）。
  /// 指纹未变时直接复用，不读行。
  String? _cacheKey;
  Map<SyncCategory, List<SyncRecord>>? _cached;

  @override
  Set<SyncCategory> get categories => _sourceAdapter.categories;

  @override
  bool get ready => _sourceAdapter.ready;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect({
    bool fresh = false,
  }) async {
    final key = await _fingerprintReader();
    final cached = _cached;
    if (!fresh && cached != null && _cacheKey == key) return cached;
    final records = await _sourceAdapter.exportRecords();
    _cacheKey = key;
    _cached = records;
    return records;
  }

  /// 释放上轮记录缓存：下一次 collect 按指纹重新导出（幂等）。
  @override
  void releaseCaches() {
    _cacheKey = null;
    _cached = null;
  }

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async {
    final outcome = await _sourceAdapter.apply(records);
    // 落地了远端记录：指纹的 MAX(versionPhysical) 不一定变化（远端版本可能
    // 小于本机最大值），缓存必须显式失效，否则下一次 collect 会复用旧视图。
    if (outcome.applied > 0) releaseCaches();
    return outcome;
  }
}
