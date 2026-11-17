/// 设备本地缓存索引的持久化端口。
///
/// 只做「整表读取 / 批量写入 / 批量删除」：上限裁剪、初始化与对账语义都在
/// `LocalCacheIndexStore`，测试可直接给假实现，不需要真实数据库。
library;

import '../models/local_cache_index.dart';

/// 索引行的唯一键（`sourceKey + songId`）。
typedef LocalCacheIndexKey = ({String sourceKey, String songId});

abstract interface class LocalCacheIndexPersistence {
  /// 全部索引行（顺序不敏感；store 自己按缓存完成时间排序）。
  Future<List<LocalCacheIndexEntry>> loadAll();

  /// 按 `(sourceKey, songId)` 幂等 upsert。
  Future<void> upsertAll(List<LocalCacheIndexEntry> entries);

  /// 按键删除；不存在的键静默忽略。
  Future<void> removeAll(Iterable<LocalCacheIndexKey> keys);
}
