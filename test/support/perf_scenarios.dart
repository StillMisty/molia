/// 帧体检共用场景动作：切目的地、滚动收藏列表。
///
/// 为什么单独一个文件：`integration_test/perf_flows_test.dart`（自己打点的
/// `molia.frame` 汇总）与 `integration_test/perf_timeline_test.dart`（VM
/// service timeline 归因）必须跑同一套手势与按键路径，否则两份数据不可比。
///
/// 这里的动作都只推进帧，不做 settle：动画 / 异步加载在 profile 下不该被
/// 测试框架等成静止。
library;

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/widgets/collection_track_list.dart';

import 'perf_app_harness.dart';

/// Ctrl+数字切桌面壳目的地（1 搜索 / 2 发现 / 3 收藏）。
Future<void> ctrlDigit(WidgetTester tester, int digit) async {
  final (logical, physical) = switch (digit) {
    1 => (LogicalKeyboardKey.digit1, PhysicalKeyboardKey.digit1),
    2 => (LogicalKeyboardKey.digit2, PhysicalKeyboardKey.digit2),
    _ => (LogicalKeyboardKey.digit3, PhysicalKeyboardKey.digit3),
  };
  await tester.sendKeyDownEvent(
    LogicalKeyboardKey.controlLeft,
    physicalKey: PhysicalKeyboardKey.controlLeft,
  );
  await tester.sendKeyEvent(logical, physicalKey: physical);
  await tester.sendKeyUpEvent(
    LogicalKeyboardKey.controlLeft,
    physicalKey: PhysicalKeyboardKey.controlLeft,
  );
  await pumpFrames(tester);
}

/// 在当前收藏列表里逐帧滚动 [times] × 12 次，每次 50px。
///
/// 逐帧 jumpTo 而不是 fling：桌面壳的列表中心可能被固定表头 / 壳层 chrome
/// 盖住，手势会命中不到；这里只测「滚动时列表构建 / 布局 / 光栅」的帧成本。
Future<void> scrollList(WidgetTester tester, {int times = 10}) async {
  final finder = find
      .descendant(
        of: find.byWidgetPredicate((widget) => widget is CollectionTrackList),
        matching: find.byType(Scrollable),
      )
      .first;
  final position = tester.state<ScrollableState>(finder).position;
  final before = position.pixels;
  for (var i = 0; i < times; i++) {
    // 逐帧推进而不是 fling：桌面壳的列表中心可能被固定表头 / 壳层 chrome
    // 盖住，手势会命中不到；这里只测「滚动时列表构建 / 布局 / 光栅」的帧成本。
    for (var step = 0; step < 12; step++) {
      final pos = math.min(position.pixels + 50, position.maxScrollExtent);
      position.jumpTo(pos);
      await tester.pump(const Duration(milliseconds: 16));
    }
  }
  if (position.pixels == before) {
    fail('列表没有产生滚动位移（场景无效）');
  }
}
