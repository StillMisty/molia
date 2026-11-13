import 'dart:collection';
import 'dart:math' as math;

/// 「最近听过」曲目在随机播放里的权重：只降低出现概率，不排除。
const double kRecentTrackShuffleWeight = 0.15;

/// 智能随机的最短队列：太短的队列怎么排都像「总在重复」。
const int kSmartShuffleMinQueue = 10;

/// 队列曲目 id + 最近播放证据 → 每个队列下标的权重。
///
/// 关闭智能随机、队列过短、证据为空或与队列完全不相交时返回 null
/// （调用方据此走与今天完全一致的均匀洗牌）。证据缺失只降级、不抛错：
/// 随机播放不能因为读不到历史而失败。
List<double>? shuffleWeightsFor({
  required List<String> trackIds,
  required Set<String> recentTrackIds,
  required bool enabled,
}) {
  if (!enabled ||
      trackIds.length < kSmartShuffleMinQueue ||
      recentTrackIds.isEmpty) {
    return null;
  }
  final weights = <double>[
    for (final id in trackIds)
      recentTrackIds.contains(id) ? kRecentTrackShuffleWeight : 1.0,
  ];
  return weights.any((weight) => weight < 1.0) ? weights : null;
}

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
///
/// 可选的 [reset] `weights` 是「少放最近听过的」的实现：本轮仍覆盖每个
/// 下标恰好一次，只是低权重项更常排到后面。权重只在生成轮次时生效，
/// 进行中的排列不会被后来的历史更新重排。
class PlaybackShuffleOrder {
  PlaybackShuffleOrder({math.Random? random})
    : _random = random ?? math.Random();

  final math.Random _random;

  List<int> _order = const [];

  /// 最近一次生成轮次时使用的权重；轮末自动重洗沿用同一份。
  ///
  /// 下一轮看到的是「上一次刷新时」的证据，而不是轮末临时查询——洗牌是
  /// 同步动作，不能在这里等数据库。
  List<double>? _weights;

  /// 排列内容版本号：重置 / 采用 / 扩展 / 重映射 / 清空 / 轮末重洗都自增。
  ///
  /// 队列投影缓存用它判断 shuffle 的 next / upNext 是否需要重算。
  int _revision = 0;

  int get revision => _revision;

  bool get isEmpty => _order.isEmpty;

  /// 本轮排列的只读视图（队列投影用；不复制、不暴露可写引用）。
  List<int> get indices => UnmodifiableListView(_order);

  /// 生成新排列（新队列 / 进入 shuffle / 新一轮），[startIndex] 置于首位。
  ///
  /// [weights] 与队列等长（见 [shuffleWeightsFor]）；提供时按权重不放回
  /// 抽样，否则保持均匀洗牌。当前曲目永远置首，不参与抽样。
  void reset(int length, {int startIndex = 0, List<double>? weights}) {
    _revision++;
    _weights = weights != null && weights.length == length ? weights : null;
    if (length <= 0) {
      _order = const [];
      return;
    }
    final first = startIndex >= 0 && startIndex < length ? startIndex : 0;
    final candidates = [
      for (var index = 0; index < length; index++)
        if (index != first) index,
    ];
    final weighted = _weights;
    if (weighted == null) {
      candidates.shuffle(_random);
    } else {
      _weightedShuffle(candidates, weighted);
    }
    _order = [first, ...candidates];
  }

  /// 采用外部已有的排列（恢复态展示过的本轮顺序 / 后端复用）。
  ///
  /// 复制传入列表而不是持有引用：调用方之后修改自己的列表（或复用一个
  /// 可变缓冲区）不能悄悄改掉正在展示、正在播放的顺序。
  void adopt(List<int> indices, {List<double>? weights}) {
    _revision++;
    _order = List<int>.of(indices);
    _weights = weights != null && weights.length == indices.length
        ? List<double>.of(weights)
        : null;
  }

  /// 按权重不放回抽样：每个候选生成一次随机键，按键降序一次排序。
  ///
  /// `key = u^(1/weight)`（u 取自注入随机源）是加权无放回抽样的标准做法；
  /// 高权重更容易拿到接近 1 的键。排序是 O(n log n)，同键按下标稳定。
  void _weightedShuffle(List<int> candidates, List<double> weights) {
    final keys = <({int index, double key})>[];
    for (final index in candidates) {
      final weight = weights[index];
      final u = _random.nextDouble();
      // u 取 0 时（随机源边界）退化成最小键，避免除零 / 非数值。
      final safeU = u <= 0 ? 1e-9 : u;
      keys.add((
        index: index,
        key: weight <= 0 ? 0.0 : math.pow(safeU, 1 / weight).toDouble(),
      ));
    }
    keys.sort((a, b) {
      final byKey = b.key.compareTo(a.key);
      return byKey != 0 ? byKey : a.index.compareTo(b.index);
    });
    candidates
      ..clear()
      ..addAll([for (final entry in keys) entry.index]);
  }

  /// 清空（停止播放 / 切出 shuffle）。
  void clear() {
    if (_order.isEmpty) return;
    _revision++;
    _order = const [];
    _weights = null;
  }

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
    _revision++;
    _order = [..._order, ...appended];
    final weights = _weights;
    if (weights != null && weights.length == oldLength) {
      // 新追加的曲目不在本轮证据里：按普通权重进入下一轮。
      _weights = [
        ...weights,
        ...List<double>.filled(newLength - oldLength, 1.0),
      ];
    }
  }

  /// 当前曲目在排列中的位置；不在排列中返回 -1。
  int positionOf(int index) => _order.indexOf(index);

  /// 队列移除一项后的排列重映射：移除该下标，其后下标整体前移。
  ///
  /// 空排列（未洗牌）保持为空；调用方保证不移除当前曲目。
  void removeIndex(int index) {
    if (_order.isEmpty) return;
    _revision++;
    _order = [
      for (final value in _order)
        if (value != index) value > index ? value - 1 : value,
    ];
    final weights = _weights;
    if (weights != null && index >= 0 && index < weights.length) {
      _weights = [...weights]..removeAt(index);
    }
  }

  /// 队列移动一项（[from] → [to]）后的排列重映射。
  ///
  /// 移动只在非随机模式发起；这里仍按「先删后插」的重映射处理，
  /// 防止模式切换窗口里残留排列把下标指错。
  void moveIndex(int from, int to) {
    if (_order.isEmpty || from == to) return;
    _revision++;
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
    final weights = _weights;
    if (weights != null &&
        from >= 0 &&
        from < weights.length &&
        to >= 0 &&
        to < weights.length) {
      final moved = weights[from];
      final next = [...weights]..removeAt(from);
      next.insert(to, moved);
      _weights = next;
    }
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
    // 轮末沿用本轮刷新时的证据：历史更新只在队列装载 / 进入随机时读取，
    // 不在切换瞬间临时查库。
    reset(length, startIndex: currentIndex, weights: _weights);
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
