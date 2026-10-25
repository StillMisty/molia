/// 队列投影纯函数：真实播放与恢复态共用的 next / previous / upNext 口径。
///
/// 表驱动覆盖线性（顺序 / 列表循环 / 单曲循环）、shuffle（排列中段 / 轮末 /
/// 单曲）与「没有顺序」的恢复态；另外钉住播放顺序优先与同 id 排除。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/queue_projection.dart';

/// 一条表驱动用例（record 让期望值直接写在用例里）。
typedef _Case = ({
  String name,
  List<String> queue,
  int currentIndex,
  PlayMode mode,
  QueueOrder order,
  String? next,
  String? previous,
  List<String> upNext,
});

void main() {
  const queue = ['a', 'b', 'c'];

  final cases = <_Case>[
    (
      name: 'sequential 中段：队列下一位 / 前一位',
      queue: queue,
      currentIndex: 1,
      mode: PlayMode.sequential,
      order: const QueueOrder(),
      next: 'c',
      previous: 'a',
      upNext: ['c'],
    ),
    (
      name: 'sequential 队尾：没有下一首',
      queue: queue,
      currentIndex: 2,
      mode: PlayMode.sequential,
      order: const QueueOrder(),
      next: null,
      previous: 'b',
      upNext: <String>[],
    ),
    (
      name: 'listLoop 队尾：下一首回绕到队首，upNext 补上队首到当前之前',
      queue: queue,
      currentIndex: 2,
      mode: PlayMode.listLoop,
      order: const QueueOrder(),
      next: 'a',
      previous: 'b',
      upNext: ['a', 'b'],
    ),
    (
      name: 'listLoop 队首：上一首回绕到队尾',
      queue: queue,
      currentIndex: 0,
      mode: PlayMode.listLoop,
      order: const QueueOrder(),
      next: 'b',
      previous: 'c',
      upNext: ['b', 'c'],
    ),
    (
      name: 'singleRepeat 的 peek / 手动切歌仍走队列下一位',
      queue: queue,
      currentIndex: 1,
      mode: PlayMode.singleRepeat,
      order: const QueueOrder(),
      next: 'c',
      previous: 'a',
      upNext: ['c'],
    ),
    (
      name: 'shuffle 排列中段：next / upNext 读本轮排列',
      queue: queue,
      currentIndex: 0,
      mode: PlayMode.shuffle,
      order: const QueueOrder(shuffleIndices: [2, 0, 1]),
      next: 'b',
      previous: null,
      upNext: ['b'],
    ),
    (
      name: 'shuffle 轮末：peek 不重洗，下一首为空',
      queue: queue,
      currentIndex: 1,
      mode: PlayMode.shuffle,
      order: const QueueOrder(shuffleIndices: [2, 0, 1]),
      next: null,
      previous: 'a',
      upNext: <String>[],
    ),
    (
      name: 'shuffle 单曲：下一首仍是自己，upNext 为空',
      queue: ['a'],
      currentIndex: 0,
      mode: PlayMode.shuffle,
      order: const QueueOrder(shuffleIndices: [0]),
      next: 'a',
      previous: null,
      upNext: <String>[],
    ),
    (
      name: 'shuffle 无顺序（恢复态）：不拿队列下标冒充下一首',
      queue: queue,
      currentIndex: 1,
      mode: PlayMode.shuffle,
      order: const QueueOrder(),
      next: null,
      previous: 'a',
      upNext: <String>[],
    ),
    (
      name: '播放顺序优先于队列前一位',
      queue: queue,
      currentIndex: 1,
      mode: PlayMode.sequential,
      order: const QueueOrder(previousIndex: 2),
      next: 'c',
      previous: 'c',
      upNext: ['c'],
    ),
    (
      name: '播放顺序越界（队列已被替换）：不回退、不猜',
      queue: queue,
      currentIndex: 1,
      mode: PlayMode.listLoop,
      order: const QueueOrder(previousIndex: 9),
      next: 'c',
      previous: null,
      upNext: ['c', 'a'],
    ),
  ];

  for (final testCase in cases) {
    test(testCase.name, () {
      final projection = projectQueue(
        testCase.queue,
        currentIndex: testCase.currentIndex,
        mode: testCase.mode,
        order: testCase.order,
      );

      expect(projection.next, testCase.next);
      expect(projection.previous, testCase.previous);
      expect(projection.upNext, testCase.upNext);
    });
  }

  test('上一首与当前同 id：排除（重复曲目槽位不当作上一首）', () {
    final queue = [
      (slot: 1, id: 'a'),
      (slot: 2, id: 'a'),
      (slot: 3, id: 'b'),
    ];
    final projection = projectQueue(
      queue,
      currentIndex: 1,
      mode: PlayMode.sequential,
      order: const QueueOrder(previousIndex: 0),
      idOf: (item) => item.id,
    );

    expect(projection.previous, isNull);
    expect(projection.next?.slot, 3);
  });

  test('空队列 / 非法下标返回空投影', () {
    for (final (queue, index) in [
      (<String>[], 0),
      (['a'], -1),
      (['a'], 1),
    ]) {
      final projection = projectQueue(
        queue,
        currentIndex: index,
        mode: PlayMode.listLoop,
      );
      expect(projection.next, isNull);
      expect(projection.previous, isNull);
      expect(projection.upNext, isEmpty);
    }
  });
}
