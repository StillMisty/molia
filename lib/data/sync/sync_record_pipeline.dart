/// 同步记录管道：收集本地视图 → 合并远端记录 → 按登记过滤 → 适配器落地 → 登记交付。
///
/// 为什么收成一层：一轮同步与完整备份都必须遵守同一组记录规则（类别过滤、
/// LWW 合并、forced delivery、只交付版本变化的胜者、交付成功才登记、适配器
/// 异常不阻断其它类别）。这些规则此前散在 `SyncRoundRunner.applyStage` 与
/// `SyncBackup.importBackupJson` 两套循环里，备份导入一旦漏掉某条规则就会与
/// 线上同步给出不同结果。这里只依赖适配器 / 登记端口，不碰传输、游标、发布
/// 台账或报告——轮次编排仍归 `SyncRoundRunner`。
///
/// 调用顺序是硬约束：先 [collect] 后 [apply]。轮次与备份都按这个顺序驱动，
/// 管道自己保留本次收集的类别与本地视图，[apply] 不需要调用方再传一份（避免
/// 「应用了没有先收集」的旁路）。
library;

import 'package:logging/logging.dart';

import '../../domain/models/device_sync.dart';
import '../../domain/ports/sync_known_store.dart';
import 'sync_adapter.dart';

/// 一次应用的结果：落地量、适配器跳过量与失败次数。
///
/// 轮次只需要 [applied] / [applyFailures]；完整备份额外用 [skipped] 还原
/// 导入界面的计数（与适配器自己的 `SyncApplyOutcome` 同义）。
class SyncPipelineApplyResult {
  const SyncPipelineApplyResult({
    this.applied = 0,
    this.skipped = 0,
    this.applyFailures = 0,
  });

  static const SyncPipelineApplyResult none = SyncPipelineApplyResult();

  final int applied;
  final int skipped;

  /// 写回本地失败的适配器次数（数据未落地，轮次据此放回入站快照）。
  final int applyFailures;
}

/// 本地收集视图：管道在 [SyncRecordPipeline.collect] 时保留，供随后的
/// [SyncRecordPipeline.apply] 做合并基线。
class _CollectedView {
  const _CollectedView({required this.categories, required this.records});

  final Set<SyncCategory> categories;
  final Map<SyncCategory, List<SyncRecord>> records;
}

/// 记录管道的唯一实现：轮次与完整备份共用。
class SyncRecordPipeline {
  SyncRecordPipeline({
    required List<SyncAdapter> adapters,
    required SyncKnownStore known,
    required String Function() deviceId,
    Logger? logger,
  }) : _adapterList = adapters,
       _knownStore = known,
       _deviceIdOf = deviceId,
       _logger = logger ?? Logger('molia.sync');

  final List<SyncAdapter> _adapterList;
  final SyncKnownStore _knownStore;
  final String Function() _deviceIdOf;
  final Logger _logger;

  /// 登记的内存视图（首次使用时加载一次，之后只写变化项）。
  Map<SyncKnownKey, SyncVersion>? _knownVersions;

  /// 上轮各适配器的收集结果（身份）与聚合视图。
  final Map<SyncAdapter, Map<SyncCategory, List<SyncRecord>>>
  _lastAdapterCollect = {};
  Map<SyncCategory, List<SyncRecord>>? _lastAggregate;
  Set<SyncCategory>? _lastAggregateCategories;

  /// 上一次收集的类别与记录：apply 的合并基线，也守住「先 collect 后 apply」。
  _CollectedView? _lastCollected;

  /// 释放轮间可重建的收集缓存（托盘隐藏 / 系统低内存）。
  ///
  /// 只清派生缓存：下一次 collect 按指纹 / 存储重新导出，不改变同步语义。
  /// 适配器自己也可能持有上一轮记录（列表 / 历史 / 统计 / 封面 base64），
  /// 必须让持有者一起放掉；幂等。
  void releaseCaches() {
    _lastAdapterCollect.clear();
    _lastAggregate = null;
    _lastAggregateCategories = null;
    _lastCollected = null;
    for (final adapter in _adapterList) {
      if (adapter is SyncAdapterCacheReleaser) adapter.releaseCaches();
    }
  }

  /// 清空已知版本登记（派生状态随新命名空间重建）。
  Future<void> resetKnown() async {
    await _knownStore.reset();
    _knownVersions = null;
  }

  /// 收集本地视图（按类别过滤、聚合适配器结果）。
  ///
  /// 适配器在指纹未变时可以返回同一份缓存对象（身份复用）；只要每个适配器
  /// 的返回值身份都没变、类别集合也没变，聚合结果与上一轮完全相同——直接
  /// 复用，省掉每轮 O(全库) 的按类别 addAll 拷贝（列表被当作不可变使用，
  /// 与适配器缓存同一约定）。
  ///
  /// 收集到的本地版本以 `putIfAbsent` 播种登记：空闲轮不向适配器交付任何
  /// 记录，远端胜者版本更高时仍会交付。播种只新增键，不覆盖已登记版本。
  Future<Map<SyncCategory, List<SyncRecord>>> collect(
    Set<SyncCategory> categories, {
    bool fresh = false,
  }) async {
    final results = <SyncAdapter, Map<SyncCategory, List<SyncRecord>>>{};
    var identicalToLastRound =
        !fresh &&
        _lastAggregate != null &&
        _lastAdapterCollect.length == _readyAdapterCount;
    for (final adapter in _adapterList) {
      if (!adapter.ready) continue;
      // 类别受限适配器（封面）只在类别被请求时读数据；其它适配器保持原
      // 调用，聚合阶段仍按 [categories] 过滤。
      final collected = adapter is CategoryScopedSyncAdapter
          ? await adapter.collectForCategories(categories, fresh: fresh)
          : await adapter.collect(fresh: fresh);
      results[adapter] = collected;
      if (identicalToLastRound &&
          !identical(_lastAdapterCollect[adapter], collected)) {
        identicalToLastRound = false;
      }
    }
    if (identicalToLastRound &&
        _sameCategorySet(_lastAggregateCategories, categories)) {
      final cached = _lastAggregate!;
      _lastCollected = _CollectedView(
        categories: {...categories},
        records: cached,
      );
      return cached;
    }
    final result = <SyncCategory, List<SyncRecord>>{};
    for (final collected in results.values) {
      for (final entry in collected.entries) {
        if (!categories.contains(entry.key)) continue;
        if (entry.value.isEmpty) continue;
        result.putIfAbsent(entry.key, () => []).addAll(entry.value);
      }
    }
    _lastAdapterCollect
      ..clear()
      ..addAll(results);
    _lastAggregate = result;
    _lastAggregateCategories = {...categories};
    _lastCollected = _CollectedView(
      categories: {...categories},
      records: result,
    );
    await _seedKnown(result);
    return result;
  }

  /// 合并一次远端载荷并只把版本变化的胜者交给适配器。
  ///
  /// [local] / [categories] 是轮次在 collect 阶段捕获的显式视图：`serveSnapshot`
  /// 可能在轮次进行中并发做 fresh 收集，若 apply 读「最近一次 collect」就会
  /// 拿错合并基线。完整备份省略这两个参数，使用自己刚 collect 的视图。
  ///
  /// [forcedKeys] 是「请求全量拿到的记录」：合并时剔除本地同版本记录，让
  /// 权威视图胜出（同版本但内容不一致 = 本地被直接改写，不能按「先出现者
  /// 胜」保留），也绕过登记过滤重复交付一次。完整备份把载荷里的全部键都作为
  /// 强制交付，保持「导入 = 与本地逐键 LWW 合并」的既有语义。
  ///
  /// 前置 [collect] 缺失时直接失败：没有本地视图就没有合并基线，静默继续会
  /// 把本地较新的记录覆盖掉。
  Future<SyncPipelineApplyResult> apply(
    SyncEnvelope remote, {
    Set<SyncKnownKey> forcedKeys = const {},
    Map<SyncCategory, List<SyncRecord>>? local,
    Set<SyncCategory>? categories,
  }) async {
    assert(
      (local == null) == (categories == null),
      'local 与 categories 必须同时提供（或都不提供，使用最近一次 collect）',
    );
    final explicit = local != null && categories != null;
    final collected = explicit
        ? _CollectedView(categories: {...categories}, records: local)
        : _lastCollected;
    if (collected == null) {
      throw StateError('SyncRecordPipeline.apply 之前必须先 collect');
    }
    final known = await _ensureKnown();

    // 强制交付的键从本地合并基线里剔除：让远端权威视图赢得同版本比较。
    final localForMerge = <SyncCategory, List<SyncRecord>>{};
    for (final entry in collected.records.entries) {
      final kept = [
        for (final record in entry.value)
          if (!forcedKeys.contains((category: entry.key, key: record.key)))
            record,
      ];
      if (kept.isNotEmpty) localForMerge[entry.key] = kept;
    }
    final merged = mergeEnvelopesByCategory([
      SyncEnvelope(
        deviceId: _deviceIdOf(),
        producedAt: 0,
        records: localForMerge,
      ),
      SyncEnvelope(
        deviceId: _deviceIdOf(),
        producedAt: 0,
        records: remote.records,
      ),
    ], categories: collected.categories);

    var applied = 0;
    var skipped = 0;
    var applyFailures = 0;
    for (final adapter in _adapterList) {
      if (!adapter.ready) continue;
      // 只交付版本变化的胜者：登记一致的键不进入适配器（变更集应用）。
      final subset = <SyncCategory, List<SyncRecord>>{};
      for (final category in adapter.categories) {
        final winners = merged[category];
        if (winners == null || winners.isEmpty) continue;
        for (final record in winners.values) {
          final key = (category: category, key: record.key);
          if (!forcedKeys.contains(key) && known[key] == record.version) {
            continue;
          }
          subset.putIfAbsent(category, () => []).add(record);
        }
      }
      if (subset.isEmpty) continue;
      try {
        final outcome = await adapter.apply(subset);
        applied += outcome.applied;
        skipped += outcome.skipped;
        // 交付成功才登记（含适配器跳过的项）：适配器对同一状态的判定
        // 是确定的，重复交付只会重复消耗；登记落库后跨重启不再重放。
        final delivered = <SyncKnownKey, SyncVersion>{};
        for (final entry in subset.entries) {
          for (final record in entry.value) {
            final key = (category: entry.key, key: record.key);
            if (known[key] == record.version) continue;
            delivered[key] = record.version;
          }
        }
        if (delivered.isNotEmpty) {
          known.addAll(delivered);
          await _knownStore.putKnownVersions(delivered);
        }
      } catch (e) {
        // 单个适配器失败不阻断其余类别（与一轮同步的边界一致）；结果计数
        // 只反映真正落地的项。轮次据此把入站快照放回队列重试。
        applyFailures++;
        _logger.warning('应用 ${adapter.runtimeType} 失败', e);
      }
    }
    return SyncPipelineApplyResult(
      applied: applied,
      skipped: skipped,
      applyFailures: applyFailures,
    );
  }

  Future<void> _seedKnown(Map<SyncCategory, List<SyncRecord>> records) async {
    if (records.isEmpty) return;
    final known = await _ensureKnown();
    for (final entry in records.entries) {
      for (final record in entry.value) {
        known.putIfAbsent((
          category: entry.key,
          key: record.key,
        ), () => record.version);
      }
    }
  }

  int get _readyAdapterCount {
    var count = 0;
    for (final adapter in _adapterList) {
      if (adapter.ready) count++;
    }
    return count;
  }

  static bool _sameCategorySet(Set<SyncCategory>? a, Set<SyncCategory> b) {
    if (a == null || a.length != b.length) return false;
    for (final category in b) {
      if (!a.contains(category)) return false;
    }
    return true;
  }

  Future<Map<SyncKnownKey, SyncVersion>> _ensureKnown() async =>
      _knownVersions ??= await _knownStore.knownVersions();
}
