/// 队列编辑策略纯函数：移动 / 移除的合法边界与当前下标平移。
///
/// 表驱动钉住恢复态与真实播放共用口径：随机模式禁止移动、当前曲目不可编辑、
/// 越界 / 原地 no-op，以及当前下标只在编辑跨过当前曲目时平移。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/queue_edit_policy.dart';

typedef _MoveCase = ({
  String name,
  PlayMode mode,
  int length,
  int currentIndex,
  int from,
  int to,
  bool allowed,
  int expectedIndex,
});

typedef _RemoveCase = ({
  String name,
  int length,
  int currentIndex,
  int index,
  bool allowed,
  int expectedIndex,
});

void main() {
  group('移动', () {
    final cases = <_MoveCase>[
      (
        name: '随机模式禁止移动',
        mode: PlayMode.shuffle,
        length: 4,
        currentIndex: 1,
        from: 3,
        to: 0,
        allowed: false,
        expectedIndex: 1,
      ),
      (
        name: '移动当前曲目本身是 no-op',
        mode: PlayMode.sequential,
        length: 4,
        currentIndex: 2,
        from: 2,
        to: 0,
        allowed: false,
        expectedIndex: 2,
      ),
      (
        name: '落到当前曲目位置是 no-op',
        mode: PlayMode.sequential,
        length: 4,
        currentIndex: 2,
        from: 0,
        to: 2,
        allowed: false,
        expectedIndex: 2,
      ),
      (
        name: 'from 越界（负数）是 no-op',
        mode: PlayMode.listLoop,
        length: 4,
        currentIndex: 1,
        from: -1,
        to: 2,
        allowed: false,
        expectedIndex: 1,
      ),
      (
        name: 'from 越界（队尾之外）是 no-op',
        mode: PlayMode.listLoop,
        length: 4,
        currentIndex: 1,
        from: 4,
        to: 0,
        allowed: false,
        expectedIndex: 1,
      ),
      (
        name: 'to 越界（负数）是 no-op',
        mode: PlayMode.listLoop,
        length: 4,
        currentIndex: 1,
        from: 3,
        to: -1,
        allowed: false,
        expectedIndex: 1,
      ),
      (
        name: 'to 越界（队尾之外）是 no-op',
        mode: PlayMode.listLoop,
        length: 4,
        currentIndex: 1,
        from: 0,
        to: 4,
        allowed: false,
        expectedIndex: 1,
      ),
      (
        name: '原地移动是 no-op',
        mode: PlayMode.sequential,
        length: 4,
        currentIndex: 2,
        from: 1,
        to: 1,
        allowed: false,
        expectedIndex: 2,
      ),
      (
        name: '空队列是 no-op',
        mode: PlayMode.sequential,
        length: 0,
        currentIndex: 0,
        from: 0,
        to: 0,
        allowed: false,
        expectedIndex: 0,
      ),
      (
        name: '单曲队列只能原地移动，no-op',
        mode: PlayMode.listLoop,
        length: 1,
        currentIndex: 0,
        from: 0,
        to: 0,
        allowed: false,
        expectedIndex: 0,
      ),
      (
        name: '当前曲目之前移动且未跨过：下标不变',
        mode: PlayMode.sequential,
        length: 5,
        currentIndex: 3,
        from: 0,
        to: 1,
        allowed: true,
        expectedIndex: 3,
      ),
      (
        name: '从当前曲目之前移到之后：当前下标前移一格',
        mode: PlayMode.listLoop,
        length: 5,
        currentIndex: 3,
        from: 1,
        to: 4,
        allowed: true,
        expectedIndex: 2,
      ),
      (
        name: '从当前曲目之后移到之前：当前下标后移一格',
        mode: PlayMode.singleRepeat,
        length: 5,
        currentIndex: 2,
        from: 4,
        to: 0,
        allowed: true,
        expectedIndex: 3,
      ),
      (
        name: '当前曲目之后移动且未跨过：下标不变',
        mode: PlayMode.listLoop,
        length: 5,
        currentIndex: 1,
        from: 3,
        to: 4,
        allowed: true,
        expectedIndex: 1,
      ),
    ];

    for (final item in cases) {
      test(item.name, () {
        final plan = planQueueMove(
          mode: item.mode,
          length: item.length,
          currentIndex: item.currentIndex,
          from: item.from,
          to: item.to,
        );
        expect(plan.allowed, item.allowed);
        expect(plan.currentIndex, item.expectedIndex);
      });
    }
  });

  group('移除', () {
    final cases = <_RemoveCase>[
      (
        name: '移除当前曲目之前：当前下标前移一格',
        length: 4,
        currentIndex: 2,
        index: 0,
        allowed: true,
        expectedIndex: 1,
      ),
      (
        name: '紧邻当前曲目之前移除：下标前移一格',
        length: 4,
        currentIndex: 2,
        index: 1,
        allowed: true,
        expectedIndex: 1,
      ),
      (
        name: '移除当前曲目本身是 no-op',
        length: 4,
        currentIndex: 2,
        index: 2,
        allowed: false,
        expectedIndex: 2,
      ),
      (
        name: '移除当前曲目之后：下标不变',
        length: 4,
        currentIndex: 1,
        index: 3,
        allowed: true,
        expectedIndex: 1,
      ),
      (
        name: '紧邻当前曲目之后移除：下标不变',
        length: 4,
        currentIndex: 1,
        index: 2,
        allowed: true,
        expectedIndex: 1,
      ),
      (
        name: 'index 越界（负数）是 no-op',
        length: 4,
        currentIndex: 1,
        index: -1,
        allowed: false,
        expectedIndex: 1,
      ),
      (
        name: 'index 越界（队尾之外）是 no-op',
        length: 4,
        currentIndex: 1,
        index: 4,
        allowed: false,
        expectedIndex: 1,
      ),
      (
        name: '空队列是 no-op',
        length: 0,
        currentIndex: 0,
        index: 0,
        allowed: false,
        expectedIndex: 0,
      ),
      (
        name: '单曲队列不可移除唯一曲目',
        length: 1,
        currentIndex: 0,
        index: 0,
        allowed: false,
        expectedIndex: 0,
      ),
    ];

    for (final item in cases) {
      test(item.name, () {
        final plan = planQueueRemove(
          length: item.length,
          currentIndex: item.currentIndex,
          index: item.index,
        );
        expect(plan.allowed, item.allowed);
        expect(plan.currentIndex, item.expectedIndex);
      });
    }
  });
}
