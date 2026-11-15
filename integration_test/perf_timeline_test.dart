import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:molia/services/app_logging.dart';

import '../test/support/perf_app_harness.dart';
import '../test/support/perf_scenarios.dart';

/// 用 VM service timeline 采样一段可归因的帧序列（DevTools 的同一数据源）。
///
/// 与 `perf_flows_test.dart` 的分工：
/// - perf_flows：应用自己用 `FrameTiming` 打点（`molia.frame`），每帧只有总耗时，
///   适合批量场景的 p50/p95/p99 回归对比；
/// - 本文件：`traceAction` 采集 VM timeline，保留每帧内部的 build / layout /
///   paint / raster / vsync 切片，能把「哪一帧、卡在哪个阶段」定位到具体帧
///   （DevTools Performance 页的归因口径），并留下可直接导入 DevTools /
///   Perfetto 的原始 trace（`build/integration_response_data.json`，由
///   `perf.sh frames <platform> --timeline` 收进结果目录）。
///
/// 运行（由 `tool/agent/perf.sh` 封装）：
///   flutter drive --profile -d linux \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/perf_timeline_test.dart
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(initAppLogging);

  testWidgets('桌面壳：收藏滚动（timeline 归因）', (tester) async {
    await pumpPerfApp(tester, desktopShell: true, favoritesCount: 1000);
    // 统一落到收藏页再计时（启动首页偏好不参与本测试）。
    await ctrlDigit(tester, 3);
    await pumpFrames(tester, frames: 90);

    // 只把滚动放进 trace：前面的装配 / 首屏加载是暖场，混进来会淹没目标场景。
    await binding.traceAction(
      () => scrollList(tester, times: 10),
      streams: const ['all'],
      reportKey: 'timeline',
    );
  });
}
