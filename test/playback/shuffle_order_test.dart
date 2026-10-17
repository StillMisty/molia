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

  group('extend（队列追加）', () {
    test('老歌保持原顺序在前，追加下标随机分布在后且恰好一次', () {
      final order = PlaybackShuffleOrder(random: Random(5))
        ..reset(3, startIndex: 0);
      final before = order.remainingAfter(0);

      order.extend(3, 6);

      final rest = order.remainingAfter(0);
      expect(rest.sublist(0, before.length), before,
          reason: '当前轮先放完老歌，顺序不被打乱');
      final appended = rest.sublist(before.length);
      expect(appended.toSet(), {3, 4, 5});
      expect(appended, hasLength(3));
    });

    test('扩展后轮末重洗覆盖全队列（追加曲目可播）', () {
      final order = PlaybackShuffleOrder(random: Random(9))
        ..reset(2, startIndex: 0);
      order.extend(2, 4);

      // 走完当前轮（老歌 + 追加歌），轮末 next 重洗新一轮。
      final played = <int>{0};
      var current = 0;
      for (var i = 0; i < 3; i++) {
        current = order.next(current);
        played.add(current);
      }
      expect(played, {0, 1, 2, 3}, reason: '一轮覆盖含追加曲目');
    });

    test('空排列 / 长度不匹配保守跳过', () {
      final order = PlaybackShuffleOrder(random: Random(1));
      order.extend(0, 3);
      expect(order.isEmpty, isTrue, reason: '未洗牌时跳过（后续 reset 重建）');

      order.reset(3, startIndex: 0);
      order.extend(2, 5);
      expect(order.remainingAfter(0), hasLength(2),
          reason: '队列长度与排列不匹配时不扩展');
    });
  });
}
