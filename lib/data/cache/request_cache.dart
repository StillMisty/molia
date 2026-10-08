import 'dart:async';

/// 请求级缓存：single-flight（并发同 key 只执行一次）+ LRU（容量上限）+ TTL。
///
/// 施工图 docs/architecture.md §2.5.2：搜索 / 取链 / 歌词 / 封面共用同一实现，
/// key 由调用方按 `{type}:{source}:{...}` 约定拼装（本类不解析 key 语义）。
///
/// 语义约定：
/// - 同 key 并发调用共享同一个 in-flight Future（single-flight）；
/// - 失败不缓存：create 抛错后条目立即移除，下一次调用会重试；
/// - 命中后该条目视为“最近使用”（LRU 顺序按访问刷新）；
/// - 淘汰优先从最旧的**已完成**条目开始，绝不淘汰 in-flight 条目，
///   保证单飞语义不被容量压力破坏（容量可能短暂超出，完成后再回收）。
class RequestCache {
  RequestCache({
    this.maxEntries = 64,
    required this.ttl,
    DateTime Function()? clock,
  })  : assert(maxEntries > 0),
        _clock = clock ?? DateTime.now;

  /// 容量上限（默认 64）。
  final int maxEntries;

  /// 条目存活时间（从 create 完成时刻起算）。
  final Duration ttl;

  final DateTime Function() _clock;

  /// 插入顺序即 LRU 顺序（最旧在前）；命中时删除并重新插入实现“最近使用”。
  final Map<String, _CacheEntry> _entries = {};

  /// 当前条目数（含 in-flight 条目），诊断/测试用。
  int get length => _entries.length;

  bool containsKey(String key) => _entries.containsKey(key);

  /// 返回 key 对应的缓存值；不存在/过期时调用 [create] 并缓存结果。
  ///
  /// 注意：同一 key 必须始终使用同一类型 T，否则命中时的类型转换会抛错。
  Future<T> getOrCreate<T>(String key, Future<T> Function() create) {
    final existing = _entries[key];
    if (existing != null) {
      // single-flight：并发同 key 直接复用同一个 Future。
      final pending = existing.pending;
      if (pending != null) {
        _touch(key, existing);
        return pending.then((value) => value as T);
      }
      final expiresAt = existing.expiresAt;
      if (expiresAt != null && _clock().isBefore(expiresAt)) {
        _touch(key, existing);
        return Future.value(existing.value as T);
      }
      _entries.remove(key); // TTL 过期：按未命中处理。
    }

    final future = Future<Object?>.sync(create);
    final entry = _CacheEntry(pending: future);
    _entries[key] = entry;
    _evictOverflow();

    future.then((value) {
      if (identical(_entries[key], entry)) {
        entry
          ..pending = null
          ..value = value
          ..expiresAt = _clock().add(ttl);
        _evictOverflow();
      }
    }, onError: (Object error, StackTrace stackTrace) {
      // 失败不缓存；被淘汰（identity 不同）时不打扰新条目。
      if (identical(_entries[key], entry)) {
        _entries.remove(key);
      }
    });

    return future.then((value) => value as T);
  }

  /// 使单个 key 失效（in-flight 条目一并移除，后续调用重新执行）。
  void invalidate(String key) {
    _entries.remove(key);
  }

  /// 使所有以 [prefix] 开头的 key 失效（如 `search:kw:`）。
  void invalidatePrefix(String prefix) {
    _entries.removeWhere((key, _) => key.startsWith(prefix));
  }

  void _touch(String key, _CacheEntry entry) {
    _entries.remove(key);
    _entries[key] = entry;
  }

  /// 超出容量时从最旧的已完成条目开始淘汰；全是 in-flight 时允许短暂超出。
  void _evictOverflow() {
    if (_entries.length <= maxEntries) return;
    for (final key in _entries.keys.toList(growable: false)) {
      if (_entries.length <= maxEntries) break;
      if (_entries[key]?.pending == null) _entries.remove(key);
    }
  }
}

class _CacheEntry {
  /// in-flight Future；完成后置空。
  Future<Object?>? pending;

  Object? value;
  DateTime? expiresAt;

  _CacheEntry({this.pending});
}
