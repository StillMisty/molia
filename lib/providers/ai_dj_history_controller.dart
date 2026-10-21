/// AI 推荐历史账本：active 批次、历史索引、按需加载缓存与保留策略。
///
/// 只负责「历史」这一块状态；批次与存储形状之间的转换由组合根注入
/// （需要 `LibraryProvider` 把 raw 还原成可播放曲目），因此本类不依赖
/// 播放 / 曲库 provider，可独立单测。通知由 `AiDjProvider` 在所有相关状态
/// 落定后统一发出，本类不持有监听。
library;

import '../domain/models/ai_dj.dart';
import '../services/ai/ai_recommendation_store.dart';

/// 存储批次 → 领域批次。由组合根提供（需要曲库把 raw 还原成 Track）。
typedef AiDjBatchDecoder = AiDjBatch Function(StoredAiBatch stored);

/// 领域批次 → 存储批次。与 [AiDjBatchDecoder] 成对注入，保证格式不变。
typedef AiDjBatchEncoder = StoredAiBatch Function(AiDjBatch batch);

/// 推荐历史控制器：Provider 只保留编排，历史读写与保留策略全部在这里。
class AiDjHistoryController {
  AiDjHistoryController({
    required AiRecommendationStore store,
    required AiDjBatchDecoder decode,
    required AiDjBatchEncoder encode,
    DateTime Function()? clock,
  })  : _store = store,
        _decode = decode,
        _encode = encode,
        _clock = clock ?? DateTime.now;

  /// 历史详情缓存上限（按需加载；不持久化）。
  ///
  /// 与历史保留上限一致，正常数据不会超过它；上限只防御异常旧索引。
  static const int _cacheLimit = 20;

  final AiRecommendationStore _store;
  final AiDjBatchDecoder _decode;
  final AiDjBatchEncoder _encode;
  final DateTime Function() _clock;

  AiDjBatch? _active;

  /// 历史索引（含 active；按生成时间倒序）。
  List<AiDjHistoryEntry> _entries = const [];
  final Map<String, AiDjBatch> _cache = {};

  /// 当前推荐（发现页轮播 / AI 页列表）。
  AiDjBatch? get active => _active;

  /// 历史索引（含 active；历史页首屏只读它）。
  List<AiDjHistoryEntry> get entries => List.unmodifiable(_entries);

  int get count => _entries.length;

  bool isActive(String id) => _active?.id == id;

  /// 读取索引 + active。启动只加载这两项，历史详情留给 [load]。
  ///
  /// 初始化不是一次用户可见的变更，通知交给调用方在启动流程结束时统一发。
  Future<void> init() async {
    AiDjHistoryIndex index;
    try {
      index = await _store.loadIndex();
    } catch (_) {
      return;
    }
    _entries = index.entries;
    final activeId = index.activeBatchId;
    if (activeId == null) return;
    final stored = await _loadStored(activeId);
    if (stored == null) return;
    final batch = _decode(stored);
    _active = batch;
    _cache[batch.id] = batch;
  }

  /// 保存一批；[makeActive] 为真时同时切换 active。
  ///
  /// 存储失败降级为内存状态（历史页仍可看到本批），与原生 store 的
  /// 静默失败语义一致。
  Future<void> archive(AiDjBatch batch, {required bool makeActive}) async {
    if (makeActive) _active = batch;
    try {
      await _store.saveBatch(_encode(batch), makeActive: makeActive);
    } catch (_) {
      // 内存账本继续可用。
    }
    _remember(batch);
  }

  /// 替换 / 不感兴趣 / 重抽未解析后更新当前批并刷新索引。
  Future<void> updateActive(AiDjBatch batch) async {
    _active = batch;
    try {
      await _store.saveBatch(_encode(batch), makeActive: true);
    } catch (_) {
      // 内存账本继续可用。
    }
    _remember(batch);
  }

  /// 按需加载历史详情（不切换 active）。
  Future<AiDjBatch?> load(String id) async {
    if (_active?.id == id) return _active;
    final cached = _cache[id];
    if (cached != null) return cached;
    final stored = await _loadStored(id);
    if (stored == null) return null;
    final batch = _decode(stored);
    _cache[id] = batch;
    if (_cache.length > _cacheLimit) _cache.remove(_cache.keys.first);
    return batch;
  }

  /// 切换 active（只动浏览列表，不动队列）；返回是否找到该批。
  Future<bool> setActive(String id) async {
    final batch = await load(id);
    if (batch == null) return false;
    _active = batch;
    _cache[batch.id] = batch;
    try {
      await _store.setActive(batch.id);
    } catch (_) {
      // 存储失败只影响下次启动恢复，内存切换仍生效。
    }
    return true;
  }

  /// 删除一批；删除 active 时回退到存储选出的最近一批。
  ///
  /// 返回 false 表示存储失败（调用方保留内存状态并记录日志）。
  Future<bool> delete(String id) async {
    final wasActive = _active?.id == id;
    AiDjHistoryMutationResult result;
    try {
      result = await _store.deleteBatch(id);
    } catch (_) {
      return false;
    }
    if (!result.ok) return false;
    _entries = result.index.entries;
    _cache.remove(id);
    if (wasActive) {
      final fallbackId = result.index.activeBatchId;
      _active = fallbackId == null ? null : await load(fallbackId);
    }
    return true;
  }

  /// 清空历史：保留 active（及其批次键）。
  ///
  /// 返回 false 表示存储失败（调用方保留内存状态并记录日志）。
  Future<bool> clear() async {
    AiDjHistoryMutationResult result;
    try {
      result = await _store.clearHistory();
    } catch (_) {
      return false;
    }
    if (!result.ok) return false;
    _entries = result.index.entries;
    final activeId = _active?.id;
    _cache.removeWhere((id, _) => id != activeId);
    return true;
  }

  Future<StoredAiBatch?> _loadStored(String id) async {
    try {
      return await _store.loadBatch(id);
    } catch (_) {
      return null;
    }
  }

  void _remember(AiDjBatch batch) {
    final entry = AiDjHistoryEntry(
      id: batch.id,
      generatedAt: batch.generatedAt,
      itemCount: batch.items.length,
      unresolvedCount: batch.unresolved.length,
      origin: batch.origin,
      preferences: batch.preferences,
    );
    _entries = [
      entry,
      for (final existing in _entries)
        if (existing.id != entry.id) existing,
    ]..sort((a, b) => b.generatedAt.compareTo(a.generatedAt));
    _cache[batch.id] = batch;
    _trimMemoryHistory();
  }

  void _trimMemoryHistory() {
    final result = trimAiDjHistory(
      _entries,
      activeBatchId: _active?.id,
      now: _clock(),
    );
    _entries = result.kept;
    final known = {for (final entry in result.kept) entry.id};
    _cache.removeWhere((id, _) => !known.contains(id));
  }
}
