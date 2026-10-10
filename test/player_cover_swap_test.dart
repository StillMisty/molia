import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/widgets/player_cover_swap.dart';

/// 切歌方向判定纯函数（[resolveCoverSwapDirection]）：规则优先级是契约，
/// 逐条固定边界——队列点选双向、随机模式上一首/轮末重洗、重复 id 取最近、
/// 无法解析兜底向前、同 id 不播。
Track _track(String id) => Track(
      id: TrackId('fake', id),
      title: 'Title $id',
      origin: TrackOrigin.lx,
      payload: {'id': id},
    );

void main() {
  final a = _track('a');
  final b = _track('b');
  final c = _track('c');
  final d = _track('d');
  final e = _track('e');

  group('规则 1：无新旧曲 / 同一首 → 不播动画', () {
    test('from 为空时返回 0', () {
      expect(
        resolveCoverSwapDirection(from: null, to: b, prevHint: b, nextHint: b),
        coverSwapNone,
      );
    });

    test('to 为空时返回 0', () {
      expect(
        resolveCoverSwapDirection(from: b, to: null, queue: [a, b, c]),
        coverSwapNone,
      );
    });

    test('新旧同 id 时返回 0（即便提示与下标都指向其它方向）', () {
      expect(
        resolveCoverSwapDirection(
          from: b,
          to: b,
          prevHint: b,
          nextHint: b,
          queue: [a, b, c, d],
          oldIndex: 3,
          newIndex: 1,
        ),
        coverSwapNone,
      );
    });
  });

  group('规则 2/3：变化前提示命中', () {
    test('命中上一首提示 → 向后（优先于队列下标向前）', () {
      // 随机模式下播放顺序与队列顺序不同：history 末位可以排在队列更后面。
      expect(
        resolveCoverSwapDirection(
          from: a,
          to: d,
          prevHint: d,
          nextHint: null,
          queue: [a, b, c, d],
          oldIndex: 0,
          newIndex: 3,
          shuffle: true,
        ),
        coverSwapBackward,
      );
    });

    test('同时命中上一首与下一首提示时按上一首（向后）', () {
      expect(
        resolveCoverSwapDirection(
          from: b,
          to: a,
          prevHint: a,
          nextHint: a,
        ),
        coverSwapBackward,
      );
    });

    test('轮末重洗命中下一首提示 → 向前（优先于下标向后）', () {
      // 重洗出的「下一首」可能排在当前曲目之前（队列下标向后），
      // 但用户实际是在轮末继续向前。
      expect(
        resolveCoverSwapDirection(
          from: c,
          to: a,
          nextHint: a,
          queue: [a, b, c],
          oldIndex: 2,
          newIndex: 0,
          shuffle: true,
        ),
        coverSwapForward,
      );
    });
  });

  group('规则 4：随机模式', () {
    test('随机模式无提示命中 → 向前（队列下标向后也不采信）', () {
      expect(
        resolveCoverSwapDirection(
          from: c,
          to: a,
          queue: [a, b, c],
          oldIndex: 2,
          newIndex: 0,
          shuffle: true,
        ),
        coverSwapForward,
      );
    });
  });

  group('规则 5：队列下标符号', () {
    test('队列点选当前之后的曲目 → 向前', () {
      expect(
        resolveCoverSwapDirection(
          from: a,
          to: c,
          queue: [a, b, c, d],
          oldIndex: 0,
          newIndex: 2,
        ),
        coverSwapForward,
      );
    });

    test('队列点选当前之前的曲目 → 向后', () {
      expect(
        resolveCoverSwapDirection(
          from: c,
          to: a,
          queue: [a, b, c, d],
          oldIndex: 2,
          newIndex: 0,
        ),
        coverSwapBackward,
      );
    });

    test('同一 id 出现多次：新位置取离旧下标最近的实例（向后）', () {
      // queue: [a, b, c, d, e, a]；当前 b(1) → a：候选 0（距离 1）/ 5（距离 4）。
      expect(
        resolveCoverSwapDirection(
          from: b,
          to: a,
          queue: [a, b, c, d, e, a],
          oldIndex: 1,
        ),
        coverSwapBackward,
      );
    });

    test('同一 id 出现多次：新位置取离旧下标最近的实例（向前）', () {
      // 当前 d(3) → a：候选 0（距离 3）/ 5（距离 2）→ 取 5 ≥ 3 向前。
      expect(
        resolveCoverSwapDirection(
          from: d,
          to: a,
          queue: [a, b, c, d, e, a],
          oldIndex: 3,
        ),
        coverSwapForward,
      );
    });

    test('新下标精确可用时优先采信（重复 id 也一样）', () {
      // queue: [a, b, c, a]；当前 c(2) → 点选队首 a（newIndex=0）：
      // 精确下标 0 < 2 向后，即使离旧下标最近的 a 实例是队尾的 3。
      expect(
        resolveCoverSwapDirection(
          from: c,
          to: a,
          queue: [a, b, c, a],
          oldIndex: 2,
          newIndex: 0,
        ),
        coverSwapBackward,
      );
    });
  });

  group('规则 6：无法解析 → 兜底向前', () {
    test('无队列信息时兜底向前', () {
      expect(
        resolveCoverSwapDirection(from: c, to: a),
        coverSwapForward,
      );
    });

    test('新曲不在队列 → 兜底向前（即便下标向后）', () {
      expect(
        resolveCoverSwapDirection(
          from: c,
          to: e,
          queue: [a, b, c, d],
          oldIndex: 2,
          newIndex: 0,
        ),
        coverSwapForward,
      );
    });

    test('旧曲不在队列 → 兜底向前', () {
      expect(
        resolveCoverSwapDirection(
          from: e,
          to: a,
          queue: [a, b, c, d],
          oldIndex: -1,
          newIndex: 0,
        ),
        coverSwapForward,
      );
    });
  });
}
