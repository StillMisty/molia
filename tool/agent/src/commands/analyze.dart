/// `analyze`：与仓库门禁同口径的 `flutter analyze`。
///
/// 默认带 `--no-pub`（与 AGENTS.md / CI 一致）；要顺带解析依赖时传 `--pub`。
library;

import 'dart:io';

import '../context.dart';

Future<void> runAnalyze(ToolContext context, List<String> args) async {
  final flutter =
      context.flutter ?? context.fail('找不到 flutter（把 Flutter 加进 PATH）');
  final passthrough = <String>[];
  var pub = false;
  for (final arg in args) {
    switch (arg) {
      case '--pub':
        pub = true;
      default:
        passthrough.add(arg);
    }
  }
  final command = [flutter, 'analyze', if (!pub) '--no-pub', ...passthrough];
  final code = await context.runInherit(command);
  if (code != 0) {
    stderr.writeln('[agent] flutter analyze 失败（exit=$code）');
    exitCode = code;
  }
}
