import 'dart:collection';
import 'dart:math' as math;

/// 洗牌播放顺序：队列下标的随机排列 + 轮次推进（纯逻辑，可单测）。
///
/// 语义：
/// - [reset]：生成 `0..length-1` 的随机排列，把起播下标置于首位；
/// - [adopt]：直接采用调用方已有的排列（恢复态展示过的本轮顺序）；
/// - [peekNext]：当前曲目在排列中的下一首；到达本轮末尾返回 null
///   （**不重洗**，保证「下一首」预览在同一曲目内稳定、可重复读取）；
/// - [next]：排列下一首；到达末尾时自动重洗新一轮（当前曲目置首），
///   保证每轮每首恰好一次，且新一轮不会立刻重复当前曲目；
/// - [remainingAfter]：本轮剩余播放顺序（队列页「接下来」展示用）。
class PlaybackShuffleOrder {
  PlaybackShuffleOrder({math.Random? random})
    : _random = random ?? math.Random();

  final math.Random _random;

  List<int> _order = const [];

  bool get isEmpty => _order.isEmpty;

  /// 本轮排列的只读视图（队列投影用；不复制、不暴露可写引用）。
  List<int> get indices => UnmodifiableListView(_order);

  /// 生成新排列（新队列 / 进入 shuffle / 新一轮），[startIndex] 置于首位。
  void reset(int length, {int startIndex = 0}) {
    if (length <= 0) {
      _order = const [];
      return;
    }
    final order = List<int>.generate(length, (index) => index)
      ..shuffle(_random);
    final first = startIndex >= 0 && startIndex < length ? startIndex : 0;
    order.remove(first);
    order.insert(0, first);
    _order = order;
  }

  /// 采用外部已有的排列（恢复态展示过的本轮顺序 / 后端复用）。
  ///
  /// 复制传入列表而不是持有引用：调用方之后修改自己的列表（或复用一个
  /// 可变缓冲区）不能悄悄改掉正在展示、正在播放的顺序。
  void adopt(List<int> indices) => _order = List<int>.of(indices);

  /// 清空（停止播放 / 切出 shuffle）。
  void clear() => _order = const [];

  /// 队列追加后扩展排列（enqueue 场景）：
  /// 新下标随机插入排列尾部——当前轮先放完老歌再放追加歌，轮末
  /// [next] 重洗时自动覆盖全队列（保持 `_order.length == 队列长度` 不变量）。
  ///
  /// [_order] 为空（未洗牌）或长度不匹配时保守跳过：后续
  /// [reset]（[peekNext]/[next]/ensure）会按新长度重建。
  void extend(int oldLength, int newLength) {
    if (_order.isEmpty ||
        newLength <= oldLength ||
        _order.length != oldLength) {
      return;
    }
    final appended = List<int>.generate(
      newLength - oldLength,
      (index) => oldLength + index,
    )..shuffle(_random);
    _order = [..._order, ...appended];
  }

  /// 当前曲目在排列中的位置；不在排列中返回 -1。
  int positionOf(int index) => _order.indexOf(index);

  /// 队列移除一项后的排列重映射：移除该下标，其后下标整体前移。
  ///
  /// 空排列（未洗牌）保持为空；调用方保证不移除当前曲目。
  void removeIndex(int index) {
    if (_order.isEmpty) return;
    _order = [
      for (final value in _order)
        if (value != index) value > index ? value - 1 : value,
    ];
  }

  /// 队列移动一项（[from] → [to]）后的排列重映射。
  ///
  /// 移动只在非随机模式发起；这里仍按「先删后插」的重映射处理，
  /// 防止模式切换窗口里残留排列把下标指错。
  void moveIndex(int from, int to) {
    if (_order.isEmpty || from == to) return;
    _order = [
      for (final value in _order)
        if (value == from)
          to
        else if (from < to && value > from && value <= to)
          value - 1
        else if (to < from && value >= to && value < from)
          value + 1
        else
          value,
    ];
  }

  /// 排列中的下一首（不重洗）；到本轮末尾返回 null。
  int? peekNext(int currentIndex) {
    final position = _order.indexOf(currentIndex);
    if (position < 0 || position + 1 >= _order.length) return null;
    return _order[position + 1];
  }

  /// 排列下一首；到达末尾时重洗新一轮并返回新排列的第二首
  ///（当前曲目置首，避免立刻重复）。
  int next(int currentIndex) {
    final position = _order.indexOf(currentIndex);
    if (position >= 0 && position + 1 < _order.length) {
      return _order[position + 1];
    }
    final length = _order.length;
    reset(length, startIndex: currentIndex);
    if (_order.isEmpty) return -1;
    if (_order.length == 1) return _order.first;
    return _order[1];
  }

  /// 本轮剩余播放顺序（当前之后）；当前不在排列中 / 已到末尾返回空。
  List<int> remainingAfter(int currentIndex) {
    final position = _order.indexOf(currentIndex);
    if (position < 0 || position + 1 >= _order.length) return const [];
    return _order.sublist(position + 1);
  }
}

/// 校验一份外部洗牌排列能否直接用于长度 [length] 的队列。
///
/// 恢复播放会把恢复态展示过的排列随请求交给后端复用；来自持久化 / 同步 /
/// 旧版本的排列可能已与当前队列错位（长度变化、重复、越界、当前曲目不在
/// 排列里）。这类排列一旦被采用，`peekNext` / `positionOf` 会指到错误曲目
/// 甚至越界，因此后端只接受完整排列，其余情况回退为新洗牌。
///
/// 返回 true 当且仅当：长度等于 [length]、每个下标都在 `0..length-1` 且
/// 无重复（即恰好覆盖整个队列）、[currentIndex] 也在排列中。
bool isValidShuffleOrder(
  List<int> indices, {
  required int length,
  required int currentIndex,
}) {
  if (indices.length != length) return false;
  if (currentIndex < 0 || currentIndex >= length) return false;
  final seen = List<bool>.filled(length, false);
  for (final index in indices) {
    if (index < 0 || index >= length || seen[index]) return false;
    seen[index] = true;
  }
  return seen[currentIndex];
}
