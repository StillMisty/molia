/// 线性队列导航（列表循环 / 顺序播放共用）。
///
/// 只处理「队列下标 +1 / -1」；随机模式有自己的洗牌排列，单曲循环的
/// 自动重播由播放服务单独判定。
library;

/// 下一首的队列下标；[wrap] 为 true（列表循环）时队尾回到队首。
///
/// 队列为空 / 下标非法返回 null；顺序播放到队尾返回 null（调用方停止）。
/// 单曲队列在 [wrap] 为 true 时返回当前下标，调用方据此重播。
int? nextQueueIndex(int currentIndex, int length, {required bool wrap}) {
  if (length <= 0 || currentIndex < 0 || currentIndex >= length) return null;
  if (currentIndex + 1 < length) return currentIndex + 1;
  return wrap ? 0 : null;
}

/// 上一首的队列下标；[wrap] 为 true（列表循环）时队首回到队尾。
///
/// 队列为空 / 下标非法返回 null；顺序播放到队首返回 null，调用方按既有
/// 语义回退到队首（重播当前）。
int? previousQueueIndex(int currentIndex, int length, {required bool wrap}) {
  if (length <= 0 || currentIndex < 0 || currentIndex >= length) return null;
  if (currentIndex > 0) return currentIndex - 1;
  return wrap ? length - 1 : null;
}
