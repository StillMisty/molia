/// 队列编辑策略（纯函数）：移动 / 移除的合法性判定与当前下标平移。
///
/// **为什么单独成模块**：恢复态（`PlaybackSessionCoordinator` 改保存会话）与
/// 真实播放（`LocalPlaybackService` 改内存队列）需要同一套边界判定与下标
/// 平移——随机模式、当前曲目、越界 / 原地 no-op 的口径一旦分叉，UI 在两种
/// 阶段就会看到不同的可编辑范围。本模块是这套编辑语义的唯一实现；列表增删
/// 本身仍由调用方完成。
library;

import '../models/play_mode.dart';

/// 队列编辑计划：是否允许，以及编辑后的当前下标。
///
/// no-op 时 [currentIndex] 保持原值，调用方只看 [allowed]。
class QueueEditPlan {
  const QueueEditPlan({required this.allowed, required this.currentIndex});

  /// 编辑是否发生（false 表示 no-op）。
  final bool allowed;

  /// 编辑后的当前曲目下标；只随「跨过当前曲目」的编辑平移。
  final int currentIndex;
}

/// 移动计划：随机模式禁止移动；越界、原地、移动 / 落到当前曲目都是 no-op。
///
/// 随机播放的下一首由洗牌排列决定，移动队列会让排列失去意义，因此随机队列
/// 只保留移除；移动当前曲目本身等于换掉正在播放的位置，也不允许。
QueueEditPlan planQueueMove({
  required PlayMode mode,
  required int length,
  required int currentIndex,
  required int from,
  required int to,
}) {
  if (mode == PlayMode.shuffle) {
    return QueueEditPlan(allowed: false, currentIndex: currentIndex);
  }
  if (from < 0 || from >= length || to < 0 || to >= length) {
    return QueueEditPlan(allowed: false, currentIndex: currentIndex);
  }
  if (from == to || from == currentIndex || to == currentIndex) {
    return QueueEditPlan(allowed: false, currentIndex: currentIndex);
  }
  return QueueEditPlan(
    allowed: true,
    currentIndex: _crossedIndex(currentIndex, from: from, to: to),
  );
}

/// 移除计划：越界与移除当前曲目都是 no-op；移除本身与播放模式无关
/// （随机队列同样允许移除，由洗牌排列另行重映射下标）。
QueueEditPlan planQueueRemove({
  required int length,
  required int currentIndex,
  required int index,
}) {
  if (index < 0 || index >= length || index == currentIndex) {
    return QueueEditPlan(allowed: false, currentIndex: currentIndex);
  }
  return QueueEditPlan(
    allowed: true,
    currentIndex: index < currentIndex ? currentIndex - 1 : currentIndex,
  );
}

/// 移动后的当前下标：只随「跨过当前曲目」的移动平移。
int _crossedIndex(int currentIndex, {required int from, required int to}) {
  if (from < to && currentIndex > from && currentIndex <= to) {
    return currentIndex - 1;
  }
  if (to < from && currentIndex >= to && currentIndex < from) {
    return currentIndex + 1;
  }
  return currentIndex;
}
