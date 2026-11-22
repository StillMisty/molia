/// `clean`：按「保留缓存」的顺序清理构建产物。
///
/// 为什么不直接 `flutter clean`：它会把 `.dart_tool/` 整个删掉，其中包括
/// `.dart_tool/hooks_runner/`（native assets 的预编译产物）。这个目录没了，
/// Android 首次构建要为 3 个 ABI 重新编译 cnativeapi，实测冷构建 2m37s；
/// 只删 `build/` 时同样能拿到干净的打包产物，但增量构建约 10–15s。
///
/// 三档清理的代价（本机实测，Android debug）：
/// - 默认：删 `build/`，保留 hooks 与 Dart 增量缓存 → 下次约 10–15s；
/// - `--deep`：再删 `.dart_tool/flutter_build` 与平台 ephemeral → 约 25s；
/// - `--full`：官方 `flutter clean` + `flutter pub get` → 约 2m30s。
library;

import 'dart:io';

import '../context.dart';

const String cleanUsage = '''
用法: dart run tool/agent/cli.dart clean [选项]

清理构建产物，默认保留 native assets 预编译缓存（.dart_tool/hooks_runner）。

选项:
  --deep     同时删除 .dart_tool/flutter_build 与各平台 ephemeral（下次约 25s）
  --full     等价 flutter clean + flutter pub get（下次 Android 构建约 2m30s）
  --dry-run  只打印将删除的路径 / 将执行的命令
  -h, --help 显示本说明

为什么默认不跑 flutter clean：它会连 .dart_tool/ 一起删掉，其中 hooks_runner
是 cnativeapi / quickjs / sqlite3 的 native assets 预编译产物。删掉后 Android
首次构建要为 3 个 ABI 重新编译 cnativeapi（实测约 2 分钟）。
''';

enum _CleanMode { normal, deep, full }

Future<void> runClean(ToolContext context, List<String> args) async {
  var mode = _CleanMode.normal;
  var dryRun = false;
  for (final arg in args) {
    switch (arg) {
      case '--deep':
        mode = _CleanMode.deep;
      case '--full':
        mode = _CleanMode.full;
      case '--dry-run':
        dryRun = true;
      case '-h' || '--help':
        stdout.write(cleanUsage);
        return;
      default:
        stderr.writeln('[agent] 未知参数：$arg（clean -h 看用法）');
        exitCode = 2;
        return;
    }
  }

  if (dryRun && mode == _CleanMode.full) {
    stdout.writeln('将执行：flutter clean && flutter pub get');
    return;
  }

  if (mode == _CleanMode.full) {
    final flutter = context.flutter;
    if (flutter == null) context.fail('找不到 flutter（把 Flutter 加进 PATH）');
    // flutter clean 会删掉 .dart_tool，之后必须 pub get 才能继续 --no-pub 构建。
    final cleanExit = await context.runInherit([flutter, 'clean']);
    if (cleanExit != 0) {
      exitCode = cleanExit;
      return;
    }
    final pubExit = await context.runInherit([
      flutter,
      'pub',
      'get',
    ], workingDirectory: context.repoRoot);
    if (pubExit != 0) {
      exitCode = pubExit;
      return;
    }
    context.log('完整清理完成；native assets 缓存已删除，下次 Android 构建会重新编译');
    return;
  }

  final targets = _targets(context.repoRoot, mode);
  if (dryRun) {
    stdout.writeln('将删除：');
    for (final path in targets) {
      stdout.writeln('  $path');
    }
    return;
  }

  var removed = 0;
  var failed = 0;
  for (final path in targets) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      context.log('跳过（不存在）：$path');
      continue;
    }
    try {
      if (type == FileSystemEntityType.directory) {
        Directory(path).deleteSync(recursive: true);
      } else {
        File(path).deleteSync();
      }
      removed++;
      context.log('已删除：$path');
    } on FileSystemException catch (error) {
      failed++;
      stderr.writeln('[agent] 删除失败：$path（${error.message}）');
    }
  }

  if (failed > 0) {
    stderr.writeln('[agent] $failed 个路径删除失败；先停掉 flutter run / Gradle 再重试');
    exitCode = 1;
    return;
  }
  context.log(
    '清理完成（$removed 个路径）；保留 .dart_tool/hooks_runner，下次构建无需重编 native assets',
  );
}

List<String> _targets(String repoRoot, _CleanMode mode) {
  String join(String relative) =>
      '$repoRoot${Platform.pathSeparator}'
      '${relative.replaceAll('/', Platform.pathSeparator)}';

  return [
    join('build'),
    if (mode != _CleanMode.normal) ...[
      join('.dart_tool/flutter_build'),
      join('linux/flutter/ephemeral'),
      join('windows/flutter/ephemeral'),
      join('macos/Flutter/ephemeral'),
      join('ios/Flutter/ephemeral'),
    ],
  ];
}
