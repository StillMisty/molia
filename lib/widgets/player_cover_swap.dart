/// 切歌方向判定（纯函数，无 Flutter 依赖）。
///
/// 封面堆叠模块（`player_cover_deck.dart`）切歌时，把「变化前」缓存的方向
/// 提示与「变化后」的新快照一起交给 [resolveCoverSwapDirection] 解析动画
/// 方向；独立成文件以便脱离 widget 树单测规则优先级。
library;

import '../domain/models/track.dart';

/// 切歌动画方向：向前（下一首 / 队列点选更靠后的曲目）。
const int coverSwapForward = 1;

/// 切歌动画方向：向后（上一首 / 队列点选更靠前的曲目）。
const int coverSwapBackward = -1;

/// 切歌动画方向：不播动画（无新曲 / 无旧曲 / 同一首）。
const int coverSwapNone = 0;

/// 解析切歌动画方向，返回 [coverSwapForward] / [coverSwapBackward] /
/// [coverSwapNone]。规则按优先级（顺序即契约，不得调换）：
///
/// 1. [from] 为空（无旧曲）、[to] 为空（无新曲）或新旧同 id → [coverSwapNone]；
/// 2. [to] 命中「变化前」的上一首提示 [prevHint]（快照 previous = 播放顺序
///    最近一首）→ 向后；随机模式下播放顺序与队列顺序无关，这条也能覆盖
///    「上一首」排在队列更后面的情况；
/// 3. [to] 命中「变化前」的下一首提示 [nextHint]（快照 next）→ 向前；
///    随机模式轮末重洗出的新「下一首」同样走这条；
/// 4. [shuffle] 随机模式 → 向前（向后路径已被第 2 条覆盖；随机模式下队列
///    下标不代表播放顺序，不可采信）；
/// 5. 否则按队列下标符号：新下标 ≥ 旧下标 → 向前，否则向后。下标优先取调用
///    方给的 [oldIndex] / [newIndex]（快照 currentIndex，重复 id 也以精确
///    下标为准）；缺失或不匹配时按 id 在 [queue] 中解析，重复实例取离另一
///    侧下标最近的；旧/新任一无法解析则跳过本条；
/// 6. 兜底 → 向前。
int resolveCoverSwapDirection({
  Track? from,
  Track? to,
  Track? prevHint,
  Track? nextHint,
  List<Track> queue = const [],
  int oldIndex = -1,
  int newIndex = -1,
  bool shuffle = false,
}) {
  // 1) 没有可播的切换：无新曲 / 无旧曲 / 同一首。
  if (from == null || to == null || from.id == to.id) return coverSwapNone;

  // 2) 变化前的上一首提示命中（播放顺序最近一首）→ 向后。
  if (prevHint != null && prevHint.id == to.id) return coverSwapBackward;

  // 3) 变化前的下一首提示命中 → 向前（含随机模式轮末重洗）。
  if (nextHint != null && nextHint.id == to.id) return coverSwapForward;

  // 4) 随机模式：队列顺序不代表播放顺序，一律向前。
  if (shuffle) return coverSwapForward;

  // 5) 队列下标符号（变化前旧下标 vs 变化后新下标）。
  final int? fromPosition =
      _resolveQueuePosition(queue, from.id, oldIndex, null);
  if (fromPosition != null) {
    final int? toPosition =
        _resolveQueuePosition(queue, to.id, newIndex, fromPosition);
    if (toPosition != null) {
      return toPosition >= fromPosition ? coverSwapForward : coverSwapBackward;
    }
  }

  // 6) 兜底：无法解析方向时按向前处理。
  return coverSwapForward;
}

/// 把 [id] 解析为 [queue] 中的下标。
///
/// 优先信任快照给出的 [exact]（命中同一 id 时直接用，重复 id 亦然）；[exact]
/// 缺失或不匹配时扫描队列，重复实例取离 [anchor] 最近的一个（距离相同取
/// 靠前的）；找不到返回 null。
int? _resolveQueuePosition(
  List<Track> queue,
  TrackId id,
  int exact,
  int? anchor,
) {
  if (exact >= 0 && exact < queue.length && queue[exact].id == id) {
    return exact;
  }
  int? best;
  for (var i = 0; i < queue.length; i++) {
    if (queue[i].id != id) continue;
    if (best == null ||
        (anchor != null && (i - anchor).abs() < (best - anchor).abs())) {
      best = i;
    }
  }
  return best;
}
