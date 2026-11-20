import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/perf/frame_stats.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/pages/statistics/statistics_heatmap.dart';
import 'package:molia/services/app_logging.dart';
import 'package:molia/widgets/collection_track_list.dart';
import 'package:molia/widgets/molia_mark.dart';
import 'package:molia/widgets/player.dart';
import 'package:motor/motor.dart';

import '../test/support/perf_app_harness.dart';
import '../test/support/perf_scenarios.dart';

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

  /// 泵帧直到播放器高度满足条件：模拟器上动画/手势落定比桌面慢，
  /// 固定 45 帧会在慢一档的机器上提前断言。
  Future<void> pumpUntilPlayerHeight(
    WidgetTester tester,
    Finder player,
    bool Function(double height) matches, {
    int maxFrames = 180,
  }) async {
    for (var i = 0; i < maxFrames; i++) {
      if (matches(tester.getSize(player).height)) return;
      await tester.pump(const Duration(milliseconds: 16));
    }
    fail('播放器高度未在 ${maxFrames * 16}ms 内达到预期');
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
    final queue = backend.snapshot.value.queue;
    for (var i = 0; i < 10; i++) {
      final next = (i + 1) % queue.length;
      final track = queue[next];
      backend.emit(
        PlaybackSnapshot(
          current: track,
          queue: queue,
          currentIndex: next,
          next: queue[(next + 1) % queue.length],
          isPlaying: true,
          duration: track.duration ?? Duration.zero,
          upNext: queue.sublist(next + 1),
        ),
        position: Duration.zero,
      );
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
    final expand = tester.widget<Player>(player).expandAnimation;
    expect(expand, isA<SingleMotionController>(), reason: '移动壳缺少展开控制器');
    final controller = expand! as SingleMotionController;
    for (var i = 0; i < 2; i++) {
      // 这里测的是展开 / 收起动画的帧成本，不是手势命中：直接驱动播放页的
      // 同一个控制器，避免测试坐标落在滚动区 / 滑杆 pan 上导致场景无效。
      controller.animateTo(0);
      await pumpUntilPlayerHeight(
        tester,
        player,
        (height) => height <= miniPlayerHeight + 1,
      );
      expect(
        tester.getSize(player).height,
        closeTo(miniPlayerHeight, 1),
        reason: '收起动画应把播放器停在迷你条',
      );
      controller.animateTo(1);
      await pumpUntilPlayerHeight(
        tester,
        player,
        (height) => height > miniPlayerHeight + 1,
      );
      expect(
        tester.getSize(player).height,
        greaterThan(miniPlayerHeight),
        reason: '展开动画应回到完整播放页',
      );
    }
    FrameStats.instance.reportNow('end');
  });

  // 以下两个场景只跑桌面：10k 内存库 seed 与真实 drift 读路径在 Android
  // 模拟器上会把 drive 启动拖到分钟级，移动链路的帧成本由上面几个场景覆盖。
  testWidgets('桌面壳：10k 收藏切换（120Hz 口径）', (tester) async {
    final realLibrary = PerfRealLibrary(favorites: 10000);
    await pumpPerfApp(
      tester,
      desktopShell: true,
      favoritesCount: 1000,
      realLibrary: realLibrary,
    );
    await ctrlDigit(tester, 3);
    // 首轮整库读 + isolate 建索引：真实 drift 路径比 fake 仓库慢，等到发布
    // 落地再开始计时（暖场帧由 beginScenario 丢弃）。
    await pumpUntil(
      tester,
      () => realLibrary.browseIndex != null,
      timeout: const Duration(seconds: 60),
      reason: '10k 真实曲库首轮构建未完成',
    );
    await pumpFrames(tester, frames: 30);
    expect(
      realLibrary.browseIndex!.tracks.length,
      greaterThanOrEqualTo(10000),
      reason: '真实浏览索引没有 10k 行',
    );

    const sourceKey = 'perf';
    const songId = 'perf-toggle-10k';
    bool hasTarget() => realLibrary.browseIndex!.tracks.any(
      (track) => track.key == '$sourceKey:$songId',
    );
    expect(hasTarget(), isFalse, reason: '目标曲目不应预先收藏');

    FrameStats.instance.beginScenario('desktop-favorites-toggle');
    // 走真实仓库的写路径：变更事件 → 150ms 防抖 → 重建索引（10k 行搬
    // isolate）→ publish → 收藏页 notify，全部落在计时窗口里。
    await realLibrary.repository.toggleFavorite(
      sourceKey: sourceKey,
      songId: songId,
      title: 'Toggle Target',
      artist: 'Perf Artist',
      album: 'Perf Album',
      durationMs: 180000,
      raw: const {'id': songId},
    );
    // 固定再泵一段：防抖 + 重建在真实异步里落地，帧样本才不止个位数。
    await pumpFrames(tester, frames: 60);
    await pumpUntil(tester, hasTarget, reason: '收藏新增未落到真实浏览索引');
    expect(hasTarget(), isTrue);

    await realLibrary.repository.toggleFavorite(
      sourceKey: sourceKey,
      songId: songId,
      title: 'Toggle Target',
      artist: 'Perf Artist',
      album: 'Perf Album',
      durationMs: 180000,
      raw: const {'id': songId},
    );
    await pumpFrames(tester, frames: 60);
    await pumpUntil(tester, () => !hasTarget(), reason: '取消收藏未从真实浏览索引移除');
    expect(hasTarget(), isFalse);
    FrameStats.instance.reportNow('end');
  }, skip: defaultTargetPlatform == TargetPlatform.android);

  testWidgets('桌面壳：统计页开页（120Hz 口径）', (tester) async {
    // 400 天、每天 1–3 条：覆盖全量日历热力图与最近 30 天的时段热力图。
    final realLibrary = PerfRealLibrary(favorites: 0, statisticsDays: 400);
    await pumpPerfApp(
      tester,
      desktopShell: true,
      favoritesCount: 1000,
      realLibrary: realLibrary,
    );
    await pumpFrames(tester, frames: 20);

    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    FrameStats.instance.beginScenario('desktop-statistics-open');
    // 直接压根 Navigator：设置页入口在桌面骨架里还有折叠二级页，直推更稳。
    await pushStatisticsPage(tester);
    // 覆盖首屏布局与图片占位后的稳定帧：热力图 / 榜单 / 指标都在这一屏。
    await pumpFrames(tester, frames: 60);
    FrameStats.instance.reportNow('end');

    expect(realLibrary.statisticsProvider.snapshot, isNotNull);
    expect(find.byType(StatisticsCalendarHeatmapCard), findsOneWidget);

    unawaited(navigator.maybePop());
    await pumpFrames(tester, frames: 10);
  }, skip: defaultTargetPlatform == TargetPlatform.android);
}
