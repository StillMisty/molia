import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/perf/frame_stats.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/services/app_logging.dart';
import 'package:molia/widgets/collection_track_list.dart';
import 'package:molia/widgets/molia_mark.dart';
import 'package:molia/widgets/player.dart';

import '../test/support/perf_app_harness.dart';

/// 帧体检场景：profile 模式下驱动真实壳层，FrameStats 按场景输出汇总。
///
/// 运行（由 `tool/agent/perf.sh` 封装）：
///   flutter drive --profile \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/perf_flows_test.dart \
///     --dart-define=MOLIA_PERF_TRACE=true
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    initAppLogging();
    FrameStats.instance.install();
  });

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

  /// 移动骨架没有软件内快捷键（`DesktopShortcuts` 只包桌面骨架），切页要
  /// 走真实的底栏入口；播放页目的地用 Molia 标志图标（唯一的一颗）。
  Future<void> openNowPlaying(WidgetTester tester, {int frames = 90}) async {
    final destination = find.descendant(
      of: find.byType(M3ENavigationBar),
      matching: find.byType(MoliaMark),
    );
    expect(destination, findsWidgets, reason: '移动底栏缺少播放页入口');
    await tester.tap(destination.first);
    await pumpFrames(tester, frames: frames);
  }

  /// 底栏收藏目的地：选中 / 未选中的心形图标成对出现，按图标查找而不是
  /// 文案（`labelBehavior: onlySelected` 时未选中项没有 label）。
  Future<void> openFavorites(WidgetTester tester, {int frames = 90}) async {
    final icon = find.descendant(
      of: find.byType(M3ENavigationBar),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Icon &&
            (widget.icon == Icons.favorite_rounded ||
                widget.icon == Icons.favorite_border_rounded),
      ),
    );
    expect(icon, findsWidgets, reason: '移动底栏缺少收藏入口');
    await tester.tap(icon.first);
    await pumpFrames(tester, frames: frames);
  }

  /// 当前确实停在播放页，且播放器是展开态（不是 72 的迷你条）。
  void expectOnNowPlaying(WidgetTester tester) {
    final player = find.byType(Player);
    expect(player, findsOneWidget, reason: '未到达播放页');
    expect(
      tester.getSize(player).height,
      greaterThan(miniPlayerHeight),
      reason: '播放页应处于展开态',
    );
  }

  /// 当前确实停在收藏页（列表可见即说明页面已切到前台）。
  void expectOnFavorites(WidgetTester tester) {
    expect(
      find.byWidgetPredicate((widget) => widget is CollectionTrackList),
      findsOneWidget,
      reason: '未到达收藏页',
    );
  }

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

  testWidgets('桌面壳：收藏滚动 / 切页 / 连续切歌', (tester) async {
    final backend = await pumpPerfApp(
      tester,
      desktopShell: true,
      favoritesCount: 1000,
    );
    // 统一落到收藏页（启动首页偏好不参与本测试），再开始计时。
    await ctrlDigit(tester, 3);
    // 等首屏收藏加载 + 图片占位稳定，再开始计时。
    await pumpFrames(tester, frames: 90);

    FrameStats.instance.beginScenario('desktop-favorites-scroll');
    await scrollList(tester);
    FrameStats.instance.reportNow('end');

    FrameStats.instance.beginScenario('desktop-library-switch');
    await ctrlDigit(tester, 1);
    await pumpFrames(tester, frames: 30);
    await scrollList(tester, times: 3);
    await ctrlDigit(tester, 3);
    await pumpFrames(tester, frames: 30);
    FrameStats.instance.reportNow('end');

    FrameStats.instance.beginScenario('desktop-track-switch');
    final queue = backend.state.value.queue;
    for (var i = 0; i < 10; i++) {
      final next = (i + 1) % queue.length;
      final track = queue[next];
      backend.emit(BackendSnapshot(
        current: track,
        queue: queue,
        currentIndex: next,
        next: queue[(next + 1) % queue.length],
        isPlaying: true,
        position: Duration.zero,
        duration: track.duration ?? Duration.zero,
        upNext: queue.sublist(next + 1),
      ));
      await pumpFrames(tester, frames: 24);
    }
    FrameStats.instance.reportNow('end');
  });

  testWidgets('移动壳：进播放页 / 返回收藏 / 反复进出', (tester) async {
    // 手机宽度才会渲染底栏 M3ENavigationBar（1440 是导航轨，且播放页走
    // 大屏两栏版式，覆盖不到移动壳的切页路径）；启动首页偏好 = 收藏。
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 1000,
      size: const Size(420, 900),
    );
    await pumpFrames(tester, frames: 90);
    expectOnFavorites(tester);

    FrameStats.instance.beginScenario('mobile-nowplaying-open');
    await openNowPlaying(tester, frames: 60);
    expectOnNowPlaying(tester);
    FrameStats.instance.reportNow('end');

    FrameStats.instance.beginScenario('mobile-nowplaying-toggle');
    // 序列：已在播放页（进）→ 回收藏 → 再进播放页。
    expectOnNowPlaying(tester);
    await openFavorites(tester);
    expectOnFavorites(tester);
    await openNowPlaying(tester);
    expectOnNowPlaying(tester);
    FrameStats.instance.reportNow('end');

    // 播放页 ⇄ 收藏反复进出：覆盖顶栏/底栏共享封面飞行 + 页中心隐藏时序 +
    // 侧邻位 reveal（离开时反向收回）。真机 raster 口径见 perf.sh frames。
    FrameStats.instance.beginScenario('mobile-nowplaying-leave-return');
    expectOnNowPlaying(tester);
    for (var i = 0; i < 3; i++) {
      await openFavorites(tester, frames: 30);
      expectOnFavorites(tester);
      await openNowPlaying(tester, frames: 30);
      expectOnNowPlaying(tester);
    }
    FrameStats.instance.reportNow('end');
  });

  testWidgets('移动壳：迷你播放器展开 / 收起（小屏）', (tester) async {
    // 1440 宽时播放页走大屏两栏版式（Player 没有 expandAnimation），所以
    // 从首帧就用手机宽度装配，播放页才会构建迷你 / 完整层。
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 1000,
      size: const Size(420, 900),
    );

    await openNowPlaying(tester);

    FrameStats.instance.beginScenario('mobile-mini-expand');
    final player = find.byType(Player);
    expect(
      tester.getSize(player).height,
      greaterThan(miniPlayerHeight),
      reason: '播放页应处于展开态',
    );
    for (var i = 0; i < 2; i++) {
      // 播放器区域下拉收起（超过半程），再点迷你条整条展开。
      await tester.drag(player, const Offset(0, 420));
      await pumpFrames(tester, frames: 45);
      expect(
        tester.getSize(player).height,
        closeTo(miniPlayerHeight, 1),
        reason: '下拉应把播放器收成迷你条',
      );
      await tester.tap(player);
      await pumpFrames(tester, frames: 60);
      expect(
        tester.getSize(player).height,
        greaterThan(miniPlayerHeight),
        reason: '点迷你条应展开完整播放页',
      );
    }
    FrameStats.instance.reportNow('end');
  });
}
