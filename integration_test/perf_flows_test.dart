import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Scrollable, ScrollableState;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:molia/app/perf/frame_stats.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/services/app_logging.dart';
import 'package:molia/widgets/collection_track_list.dart';

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

  testWidgets('移动壳：进播放页 / 展开收起', (tester) async {
    await pumpPerfApp(
      tester,
      desktopShell: false,
      favoritesCount: 1000,
    );
    await ctrlDigit(tester, 3);
    await pumpFrames(tester, frames: 90);

    FrameStats.instance.beginScenario('mobile-nowplaying-open');
    await ctrlDigit(tester, 2);
    await pumpFrames(tester, frames: 60);
    FrameStats.instance.reportNow('end');

    FrameStats.instance.beginScenario('mobile-nowplaying-toggle');
    await ctrlDigit(tester, 2);
    await pumpFrames(tester, frames: 90);
    await ctrlDigit(tester, 2);
    await pumpFrames(tester, frames: 90);
    FrameStats.instance.reportNow('end');

    // 播放页 ⇄ 收藏反复进出：覆盖顶栏/底栏共享封面飞行 + 页中心隐藏时序 +
    // 侧邻位 reveal（离开时反向收回）。真机 raster 口径见 perf.sh frames。
    FrameStats.instance.beginScenario('mobile-nowplaying-leave-return');
    await ctrlDigit(tester, 3);
    await pumpFrames(tester, frames: 30);
    for (var i = 0; i < 3; i++) {
      await ctrlDigit(tester, 2);
      await pumpFrames(tester, frames: 30);
      await ctrlDigit(tester, 3);
      await pumpFrames(tester, frames: 30);
    }
    FrameStats.instance.reportNow('end');
  });
}
