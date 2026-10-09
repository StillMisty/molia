import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/playback/shuffle_order.dart';

/// 洗牌播放顺序（纯逻辑）：排列覆盖、起播置首、轮末重洗、预览稳定。
void main() {
  test('reset 覆盖全部下标且起播置首', () {
    final order = PlaybackShuffleOrder(random: Random(7))
      ..reset(5, startIndex: 3);

    expect(order.positionOf(3), 0);
    final remaining = order.remainingAfter(3);
    expect(remaining, hasLength(4));
    expect({3, ...remaining}, {0, 1, 2, 3, 4});
  });

  test('next 走完一轮不重复，末尾自动重洗新一轮', () {
    final order = PlaybackShuffleOrder(random: Random(1))
      ..reset(4, startIndex: 0);

    final played = <int>[0];
    var current = 0;
    for (var i = 0; i < 3; i++) {
      current = order.next(current);
      expect(played, isNot(contains(current)), reason: '同一轮不应重复');
      played.add(current);
    }
    expect(played.toSet(), {0, 1, 2, 3});

    // 一轮结束：重洗新一轮，下一首不应等于当前曲目。
    final nextRoundFirst = order.next(current);
    expect(nextRoundFirst, isNot(current));
    expect(order.remainingAfter(current), hasLength(3));
  });

  test('peekNext 到末尾返回 null 且不重洗（连续读取稳定）', () {
    final order = PlaybackShuffleOrder(random: Random(2))
      ..reset(3, startIndex: 1);

    final second = order.peekNext(1);
    expect(second, isNotNull);
    final third = order.peekNext(second!);
    expect(third, isNotNull);
    expect(order.peekNext(third!), isNull);
    expect(order.peekNext(third), isNull, reason: '读取预览不应触发重洗');
    expect(order.remainingAfter(1), [second, third]);
  });

  test('reset(0) 清空；单曲队列 next 返回自身', () {
    final order = PlaybackShuffleOrder(random: Random(3))..reset(0);
    expect(order.isEmpty, isTrue);
    expect(order.remainingAfter(0), isEmpty);

    order.reset(1, startIndex: 0);
    expect(order.next(0), 0);
    expect(order.peekNext(0), isNull);
  });
}
