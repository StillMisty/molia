import 'dart:collection';
import 'dart:math' as math;

/// 洗牌播放顺序：队列下标的随机排列 + 轮次推进（纯逻辑，可单测）。
///
/// 语义：
/// - [reset]：生成 `0..length-1` 的随机排列，把起播下标置于首位；
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
