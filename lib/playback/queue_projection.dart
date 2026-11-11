/// 队列投影：把「队列 + 当前下标 + 模式 + 播放顺序」推导成快照里的
/// `next` / `previous` / `previousOfPrevious` / `upNext` / `upNextIndices`。
///
/// **为什么单独成模块**：真实播放（`LocalPlaybackService`）与冷启动恢复态
/// （`PlaybackSessionCoordinator`）原本各写一套近似——恢复态只能按下标
/// `±1` 推，洗牌顺序还要另起一套逻辑；「排除与当前同 id 的上一首」也复制了
/// 两份。投影收成纯函数后，两处对同一个 [PlaybackSnapshot] 形状只有一种口径。
///
/// **恢复态的限制**：播放顺序栈不落盘，恢复态调用时把
/// [QueueOrder.previousIndex] / [QueueOrder.previousOfPreviousIndex] 留空，
/// previous / previousOfPrevious 只按队列前一位依次回退。洗牌排列虽然也不
/// 落盘，但 `PlaybackSessionCoordinator` 装载恢复态时会生成一份**会话内**的
/// 本轮顺序（当前曲目置首）并通过 [QueueOrder.shuffleIndices] 传入，因此
/// 恢复态 shuffle 的 next / upNext 与恢复播放共用同一顺序，不再为空。
/// 调用方确实没有排列时仍可传 null（next 为 null、upNext 为空——「不知道」
/// 不伪装成线性下一首），这是 [QueueOrder] 保留的 null 语义。
library;

import '../models/play_mode.dart';
import 'queue_navigation.dart';

/// 投影用的播放顺序。
///
/// 字段的 `null` 都是有意义的事实（无顺序），不是「用下标近似」：
/// - [shuffleIndices]：本轮洗牌排列（队列下标，当前曲目在其中）；调用方
///   没有排列时传 null（shuffle 的 next / upNext 为空）。恢复态由
///   `PlaybackSessionCoordinator` 装载时生成本轮顺序后传入。
/// - [previousIndex]：实际播放顺序栈的最近一首；新会话 / 恢复态没有栈，
///   传 null（`previous` 才回退到队列前一位）。
/// - [previousOfPreviousIndex]：播放顺序栈的次近一首；栈不足两项时为 null，
///   投影会回退到「上一首」的队列前一位。
class QueueOrder {
  const QueueOrder({
    this.shuffleIndices,
    this.previousIndex,
    this.previousOfPreviousIndex,
  });

  final List<int>? shuffleIndices;
  final int? previousIndex;
  final int? previousOfPreviousIndex;
}

/// 队列投影结果（与 `PlaybackSnapshot` 的四个字段同形）。
class QueueProjection<T> {
  const QueueProjection({
    this.next,
    this.previous,
    this.previousOfPrevious,
    this.upNext = const [],
    this.upNextIndices = const [],
  });

  /// 按当前模式解析出的下一首（shuffle 为排列中的下一首，轮末为空）。
  final T? next;

  /// 可展示的上一首（播放顺序最近一首 → 队列前一位；与当前同 id 为 null）。
  final T? previous;

  /// 可展示的再上一首：播放顺序次近一首 → 「上一首」的队列前一位。
  ///
  /// 只用于封面左槽向后拖动的源侧前瞻；`previous` 为 null 时恒为 null。
  final T? previousOfPrevious;

  /// 实际播放顺序中当前曲目之后的曲目（队列面板「接下来」）。
  final List<T> upNext;

  /// [upNext] 对应在完整队列中的下标：队列行编辑命令必须用真实下标，
  /// 不能把面板行号当队列下标（shuffle / 列表循环回绕都会错位）。
  final List<int> upNextIndices;
}

/// 队列投影的缓存键：只有会改变投影结果的状态才参与。
///
/// 位置 tick（~400ms）只走独立 position 通道，队列 / 下标 / 模式 /
/// 播放顺序 / 洗牌排列都不变；用这个键命中缓存后，快照重建不再跑 O(N) 的
/// `projectQueue` 与 upNext 映射。
///
/// [playbackOrderRevision] / [shuffleOrderRevision] 是播放顺序栈与洗牌排列
/// 的内容版本号：它们可能在队列与当前下标都不变时被修改（例如同一首上弹栈），
/// 必须一起参与键。
class QueueProjectionKey {
  const QueueProjectionKey({
    required this.queueRevision,
    required this.currentIndex,
    required this.mode,
    this.playbackOrderRevision = 0,
    this.shuffleOrderRevision = 0,
  });

  /// 队列内容版本（`LocalPlaybackService.queueRevision`）。
  final int queueRevision;

  /// 当前曲目下标。
  final int currentIndex;

  /// 播放模式。
  final PlayMode mode;

  /// 播放顺序栈的内容版本（previous / previousOfPrevious 的输入）。
  final int playbackOrderRevision;

  /// 洗牌排列的内容版本（shuffle 的 next / upNext 的输入）。
  final int shuffleOrderRevision;

  @override
  bool operator ==(Object other) =>
      other is QueueProjectionKey &&
      other.queueRevision == queueRevision &&
      other.currentIndex == currentIndex &&
      other.mode == mode &&
      other.playbackOrderRevision == playbackOrderRevision &&
      other.shuffleOrderRevision == shuffleOrderRevision;

  @override
  int get hashCode => Object.hash(
    queueRevision,
    currentIndex,
    mode,
    playbackOrderRevision,
    shuffleOrderRevision,
  );
}

/// 记忆化队列投影：键不变时复用同一份 [QueueProjection] 实例。
///
/// 复用实例（而不是只复用值）很重要：快照 `==` 对 `upNext` / `upNextIndices`
/// 的深比较会先走 `identical` 短路，位置 tick 的整份快照比较因此是 O(1)，
/// 而不是每个 tick 都遍历一遍大队列。
class QueueProjectionCache<T> {
  QueueProjectionKey? _key;
  QueueProjection<T>? _projection;

  /// 当前缓存键；从未计算过为 null。
  QueueProjectionKey? get key => _key;

  /// 命中 [key] 时返回上一份投影，否则调用 [compute] 并记住结果。
  QueueProjection<T> resolve({
    required QueueProjectionKey key,
    required QueueProjection<T> Function() compute,
  }) {
    final cached = _projection;
    if (cached != null && key == _key) return cached;
    final projection = compute();
    _key = key;
    _projection = projection;
    return projection;
  }

  /// 释放缓存（停止播放 / 队列整体替换后不再需要旧投影时调用）。
  void clear() {
    _key = null;
    _projection = null;
  }
}

/// 推导队列投影（纯函数；越界 / 空队列返回空投影）。
///
/// [idOf] 决定「同一首」的判据（真实播放用 `SourceTrack.id`，恢复态用
/// `Track.id.uri`）：上一首与当前同 id 时返回 null——队首的「重播当前」
/// 不算上一首。省略时按对象相等判（测试 / 单槽位场景）。
QueueProjection<T> projectQueue<T>(
  List<T> queue, {
  required int currentIndex,
  required PlayMode mode,
  QueueOrder order = const QueueOrder(),
  Object Function(T track)? idOf,
}) {
  if (queue.isEmpty || currentIndex < 0 || currentIndex >= queue.length) {
    return QueueProjection<T>();
  }

  final current = queue[currentIndex];
  bool sameAsCurrent(int index) {
    final candidate = queue[index];
    final id = idOf;
    return id == null ? candidate == current : id(candidate) == id(current);
  }

  final next = _nextIndex(
    queue.length,
    currentIndex,
    mode,
    order.shuffleIndices,
  );
  final previous = _previousIndex(
    queue.length,
    currentIndex,
    mode,
    order.previousIndex,
    sameAsCurrent,
  );
  final previousOfPrevious = _previousOfPreviousIndex(
    queue.length,
    mode,
    previous,
    order.previousOfPreviousIndex,
  );
  final upNext = _upNextIndices(
    queue.length,
    currentIndex,
    mode,
    order.shuffleIndices,
  );

  return QueueProjection<T>(
    next: next == null ? null : queue[next],
    previous: previous == null ? null : queue[previous],
    previousOfPrevious: previousOfPrevious == null
        ? null
        : queue[previousOfPrevious],
    upNext: List<T>.unmodifiable([for (final index in upNext) queue[index]]),
    upNextIndices: List<int>.unmodifiable(upNext),
  );
}

/// 下一首下标：shuffle 读排列（不重洗，轮末 null）；线性模式走
/// [nextQueueIndex]（列表循环回绕，单曲循环只影响「自动播完」的重播判定，
/// 手动切歌 / 预览仍走队列下一位）。
int? _nextIndex(
  int length,
  int currentIndex,
  PlayMode mode,
  List<int>? shuffleIndices,
) {
  switch (mode) {
    case PlayMode.shuffle:
      // 单曲队列的「下一首」就是自己（与既有服务语义一致）。
      if (length <= 1) return currentIndex;
      final order = shuffleIndices;
      if (order == null) return null;
      final position = order.indexOf(currentIndex);
      if (position < 0 || position + 1 >= order.length) return null;
      final index = order[position + 1];
      return index >= 0 && index < length ? index : null;
    case PlayMode.listLoop:
      return nextQueueIndex(currentIndex, length, wrap: true);
    case PlayMode.sequential:
    case PlayMode.singleRepeat:
      return nextQueueIndex(currentIndex, length, wrap: false);
  }
}

/// 上一首下标：播放顺序栈优先；没有栈时回退队列前一位（列表循环回绕）。
/// 播放顺序里的越界下标（队列已被替换）不回退——与服务的既有语义一致。
int? _previousIndex(
  int length,
  int currentIndex,
  PlayMode mode,
  int? playedPreviousIndex,
  bool Function(int index) sameAsCurrent,
) {
  final int? index;
  if (playedPreviousIndex != null) {
    index = playedPreviousIndex >= 0 && playedPreviousIndex < length
        ? playedPreviousIndex
        : null;
  } else {
    index = previousQueueIndex(
      currentIndex,
      length,
      wrap: mode == PlayMode.listLoop,
    );
  }
  if (index == null || sameAsCurrent(index)) return null;
  return index;
}

/// 再上一首下标：播放顺序栈次顶优先；栈不足两项（或没有栈）时回退到
/// 「上一首」的队列前一位（列表循环回绕）。
///
/// 栈次顶存在但越界时不回退——与 [previous] 对越界栈顶的处理一致；
/// [previous] 为 null（无可展示上一首）时再上一首也为 null。
int? _previousOfPreviousIndex(
  int length,
  PlayMode mode,
  int? previousIndex,
  int? playedPreviousOfPreviousIndex,
) {
  if (previousIndex == null) return null;
  if (playedPreviousOfPreviousIndex != null) {
    return playedPreviousOfPreviousIndex >= 0 &&
            playedPreviousOfPreviousIndex < length
        ? playedPreviousOfPreviousIndex
        : null;
  }
  return previousQueueIndex(
    previousIndex,
    length,
    wrap: mode == PlayMode.listLoop,
  );
}

/// 接下来：shuffle 用本轮排列的剩余（无排列 = 空）；列表循环补上队首到
/// 当前之前；顺序 / 单曲循环只保留队列后段。
List<int> _upNextIndices(
  int length,
  int currentIndex,
  PlayMode mode,
  List<int>? shuffleIndices,
) {
  switch (mode) {
    case PlayMode.shuffle:
      if (length <= 1) return const [];
      final order = shuffleIndices;
      if (order == null) return const [];
      final position = order.indexOf(currentIndex);
      if (position < 0) return const [];
      return [
        for (final index in order.skip(position + 1))
          if (index >= 0 && index < length) index,
      ];
    case PlayMode.listLoop:
      return [
        for (var i = currentIndex + 1; i < length; i++) i,
        for (var i = 0; i < currentIndex; i++) i,
      ];
    case PlayMode.sequential:
    case PlayMode.singleRepeat:
      return [for (var i = currentIndex + 1; i < length; i++) i];
  }
}
