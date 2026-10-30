/// 资料库读侧的内存策略：播放历史顺序 / 收藏计数的唯一实现。
///
/// 这些规则此前散在 `LibraryProvider` 里，和仓库的 SQL 真值（
/// `ORDER BY playedAt DESC, rowid DESC`、列表 COUNT）各写一份；本模块把它们
/// 收成纯函数，provider 只负责持有状态并调用。
///
/// 纯 Dart：不依赖 Flutter / drift，表驱动单测直接覆盖。
library;

import '../domain/models/library.dart';

/// 播放历史的内存顺序策略。
///
/// 仓库真值：`ORDER BY playedAt DESC, rowid DESC`（`LibraryRepository.listHistory`
/// 与 `LibraryWriteEngine.trimHistory` 共用同一口径）。内存侧不读隐式 rowid，
/// 因此同一毫秒的并列条目按**当前下标**保持稳定。
abstract final class LibraryHistoryOrder {
  /// 历史唯一键（与仓库 `(sourceKey, songId)` 唯一约束一致）。
  static String keyOf(PlayHistoryEntry entry) =>
      '${entry.sourceKey}:${entry.songId}';

  /// 整表重载的稳定合并。
  ///
  /// 已存在条目保持 [current] 的相对顺序（内容用 [fresh] 的最新值），全新
  /// 条目按最近优先插到最前（[fresh] 本身即最近优先）。
  ///
  /// 为什么冻结顺序：播放历史 / 本地歌曲列表在浏览期间不该因重播而即时重排
  /// （刚点的歌跳到列表顶部会打断浏览）；要按最新播放顺序刷新时，由消费方
  /// 显式调用 [resortByRecency]。
  static List<PlayHistoryEntry> merge({
    required List<PlayHistoryEntry> current,
    required List<PlayHistoryEntry> fresh,
  }) {
    final freshByKey = {for (final entry in fresh) keyOf(entry): entry};
    final ordered = <PlayHistoryEntry>[];
    for (final entry in current) {
      final updated = freshByKey.remove(keyOf(entry));
      if (updated != null) ordered.add(updated);
    }
    if (freshByKey.isEmpty) return ordered;
    return [
      for (final entry in fresh)
        if (freshByKey.containsKey(keyOf(entry))) entry,
      ...ordered,
    ];
  }

  /// 单条历史写入的内存补丁。
  ///
  /// 已有条目原位替换（重播不打断浏览），新条目插到最前；超出 [limit] 时
  /// 裁掉尾部最旧记录。
  static List<PlayHistoryEntry> applyEntry(
    List<PlayHistoryEntry> current,
    PlayHistoryEntry entry, {
    required int limit,
  }) {
    final key = keyOf(entry);
    final index = current.indexWhere((item) => keyOf(item) == key);
    final next = List<PlayHistoryEntry>.of(current);
    if (index >= 0) {
      next[index] = entry;
    } else {
      next.insert(0, entry);
    }
    if (next.length > limit) {
      next.removeRange(limit, next.length);
    }
    return next;
  }

  /// 按最近播放（`playedAt` 倒序）重排；时间相同的条目保持当前相对顺序。
  static List<PlayHistoryEntry> resortByRecency(
    List<PlayHistoryEntry> entries,
  ) {
    final decorated =
        [for (var i = 0; i < entries.length; i++) (entry: entries[i], index: i)]
          ..sort((a, b) {
            final byTime = b.entry.playedAt.compareTo(a.entry.playedAt);
            return byTime != 0 ? byTime : a.index.compareTo(b.index);
          });
    return [for (final item in decorated) item.entry];
  }
}

/// 默认收藏列表曲目计数的优先级策略。
///
/// 优先级：整表收藏键 > 已加载列表长度 > 当前计数 ±1。
/// 前两者都是权威快照，乐观 toggle 重放时不会把校准已包含的切换再算一次；
/// 只有两者都不可用时才在现有计数上做单步增减。
abstract final class FavoriteCountPolicy {
  static int trackCount({
    /// 收藏键是否来自仓库整表（而非只有一次乐观 toggle）。
    required bool authoritative,

    /// 整表收藏键数；[authoritative] 为 true 时必须传入。
    required int favoriteKeyCount,

    /// 已加载的收藏列表长度；null = 尚未加载。
    required int? loadedTrackCount,

    /// 当前显示的计数。
    required int currentCount,

    /// 本次 toggle 的方向：> 0 收藏（+1），< 0 取消（-1），0 不变。
    required int delta,
  }) {
    if (authoritative) return favoriteKeyCount;
    if (loadedTrackCount != null) return loadedTrackCount;
    if (delta > 0) return currentCount + 1;
    if (delta < 0) return currentCount > 0 ? currentCount - 1 : 0;
    return currentCount;
  }
}
