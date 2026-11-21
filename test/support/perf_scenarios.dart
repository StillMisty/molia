/// 帧体检共用场景动作：切目的地、滚动收藏列表、往返改窗口尺寸、直推统计页。
///
/// 为什么单独一个文件：`integration_test/perf_flows_test.dart`（自己打点的
/// `molia.frame` 汇总）与 `integration_test/perf_timeline_test.dart`（VM
/// service timeline 归因）必须跑同一套手势与按键路径，否则两份数据不可比。
///
/// 这里的动作都只推进帧，不做 settle：动画 / 异步加载在 profile 下不该被
/// 测试框架等成静止。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/pages/play_statistics_page.dart';
import 'package:molia/widgets/collection_track_list.dart';
import 'package:molia/widgets/statistics/listening_heatmap.dart';

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

/// 在两个桌面窗口尺寸之间逐帧往返（默认 1440×900 ↔ 1100×720 逻辑像素）。
///
/// 为什么改 `tester.view` 而不是真窗口：桌面 `flutter drive` 的 raster 时间不可
/// 信（窗口表面由宿主合成，`FrameTiming.raster` 恒 0）；真窗口 resize 还会把
/// 窗口管理器 / 合成器的成本混进来。这里要的是同机可复现的「尺寸变化 → 重建 +
/// 重排（+ 提交绘制）」成本：设置 physicalSize / physicalConstraints 后，框架
/// 走与真窗口相同的 MetricsChanged → RenderView 重排路径，只是不搬动 OS 窗口，
/// 因此数字只能用于 build / layout 的同机 A/B，不能当光栅基线。
///
/// 两端都在 expanded 档（宽 ≥ 840）：跨断点会切换导航轨 / 两栏版式，测到的就
/// 变成「版式切换」而不是「同一版式被拉宽拉窄」，A/B 不干净。
///
/// 每段不是「设完端点只泵一帧」：端点之间按 [stepsPerSweep] 逐帧逼近，步幅接近
/// 真实拖拽，也避免端点后的大量空闲帧稀释分位数。默认 6 个来回 × 2 段 × 9 步 =
/// 108 个 16ms 帧；最后一步回到 [large]（通常就是原尺寸），恢复不再多泵帧。
Future<void> resizeWindow(
  WidgetTester tester, {
  int cycles = 6,
  int stepsPerSweep = 9,
  Size large = const Size(1440, 900),
  Size small = const Size(1100, 720),
}) async {
  assert(cycles > 0 && stepsPerSweep > 0);
  final view = tester.view;
  final ratio = view.devicePixelRatio;
  final original = view.physicalSize;

  Size physical(Size logical) =>
      Size(logical.width * ratio, logical.height * ratio);

  // RenderView 是逻辑尺寸：尺寸没传下去时帧照样在跑，但测到的是空闲帧，
  // 场景会静默失效，所以端点必须核对一次。
  void expectLogicalSize(Size expected) {
    final actual = tester.binding.renderViews.first.size;
    if ((actual.width - expected.width).abs() > 1 ||
        (actual.height - expected.height).abs() > 1) {
      fail('窗口尺寸没有生效：期望 $expected，实际 $actual');
    }
  }

  try {
    final largePhysical = physical(large);
    if (view.physicalSize != largePhysical) {
      view.physicalSize = largePhysical;
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (var cycle = 0; cycle < cycles; cycle++) {
      for (var step = 1; step <= stepsPerSweep; step++) {
        final target = Size.lerp(large, small, step / stepsPerSweep)!;
        view.physicalSize = physical(target);
        await tester.pump(const Duration(milliseconds: 16));
      }
      if (cycle == 0) expectLogicalSize(small);
      for (var step = 1; step <= stepsPerSweep; step++) {
        final target = Size.lerp(small, large, step / stepsPerSweep)!;
        view.physicalSize = physical(target);
        await tester.pump(const Duration(milliseconds: 16));
      }
      if (cycle == 0) expectLogicalSize(large);
    }
  } finally {
    if (view.physicalSize != original) {
      view.physicalSize = original;
      await tester.pump(const Duration(milliseconds: 16));
    }
  }
}

/// 直接把统计页压在根 Navigator 上，并等首屏（时段热力图）出现。
///
/// 走设置页入口会先经过桌面骨架的折叠二级页，把「开页」成本混进导航动画；
/// 这里测的是页面自身首帧。等待条件只看首屏要素，不做 settle：range 切换 /
/// 榜单图片占位这些异步还在继续，settle 会把它们的帧从采样里排掉。
Future<void> pushStatisticsPage(WidgetTester tester) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  unawaited(
    navigator.push<void>(
      MaterialPageRoute<void>(builder: (_) => const PlayStatisticsPage()),
    ),
  );
  await pumpUntil(
    tester,
    () => find.byType(WeekdayHourHeatmap).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 30),
    reason: '统计页首屏（时段热力图）未出现',
  );
}
