/// 启动子阶段埋点：与 `main.dart` 的 `molia.startup` 阶段行同一 logger 与格式，
/// `tool/agent/startup.sh` 会自动把它们收进汇总表。
///
/// 为什么单独成文件：各 stack builder 都能用同一条口径记录「自己这段等了多少」，
/// 排查启动回归时不必再临时加日志；只记录构建期的关键 await，不进入热路径。
library;

import 'package:logging/logging.dart';

final _startupLog = Logger('molia.startup');

/// 记录一个子阶段的耗时（[watch] 从该阶段开始时计时）。
void markStartupStep(String stage, Stopwatch watch) {
  _startupLog.info('$stage：${watch.elapsedMilliseconds}ms');
}
