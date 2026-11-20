import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:molia/services/app_logging.dart';

import '../test/support/perf_app_harness.dart';
import '../test/support/perf_scenarios.dart';

/// 统计页开页的 VM timeline 归因（手动运行，不进默认套件）。
///
/// 与 `perf_timeline_test.dart` 同一套口径，只是场景不同：默认 timeline
/// 入口采收藏滚动，而统计页开页的首帧成本要单独看（400 天数据、日历 +
/// 7×24 热力图同帧构建）。跑法与 `perf.sh frames linux --timeline` 相同：
///
/// ```bash
/// flutter drive --profile -d linux \
///   --driver=test_driver/integration_test.dart \
///   --target=integration_test/perf_statistics_timeline_test.dart
/// ```
///
/// 产物在 `build/integration_response_data.json`，用
/// `dart run tool/agent/cli.dart perf timeline <json> --out summary.md` 汇总。
///
/// `semanticsEnabled: false`：对齐生产默认（没有读屏 / AT 时不建语义树）。
/// 注意本机 Xvfb + GTK 下 `platformDispatcher.semanticsEnabled` 仍是 true
/// （at-spi 可用，GTK 会加载 accessibility bridge），所以 trace 里照样有
/// 约 12ms 的 SEMANTICS；换到没有 AT 的桌面这一项会自动归零。`perf_flows`
/// 的 `molia.frame` 采集走默认（开），两处对比时记得这一段是环境相关。
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(initAppLogging);

  testWidgets('桌面壳：统计页开页（timeline 归因）', (tester) async {
    // 与 perf_flows 的 `desktop-statistics-open` 同一份数据：400 天，
    // 日历热力图全量、作息热力图最近 30 天。
    final realLibrary = PerfRealLibrary(favorites: 0, statisticsDays: 400);
    await pumpPerfApp(
      tester,
      desktopShell: true,
      favoritesCount: 1000,
      realLibrary: realLibrary,
    );
    await pumpFrames(tester, frames: 20);

    // trace 只覆盖 push + 首屏 + 稳定帧：前面的装配 / 首屏加载是暖场，
    // 混进来会淹没目标场景。
    await binding.traceAction(
      () async {
        await pushStatisticsPage(tester);
        await pumpFrames(tester, frames: 60);
      },
      streams: const ['all'],
      reportKey: 'timeline',
    );
  }, semanticsEnabled: false);
}
