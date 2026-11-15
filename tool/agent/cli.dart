/// molia 跨端工具 CLI（Dart 实现，Linux / macOS / Windows 共用一套命令）。
///
/// 为什么有这个入口：原来的 `tool/agent/*.sh` 只能在 WSL / Linux 跑，
/// Windows 开发机没有 bash（也不保证有 Python），于是同一件事维护了三份
/// 实现（sh / ps1 / py）。这里把「能在三端等价执行」的部分收进来，平台
/// 差异留给各命令内部的平台分支或后端脚本。
///
/// 用法：`dart run tool/agent/cli.dart <命令> [参数]`
library;

import 'dart:io';

import 'src/apk_size.dart';
import 'src/context.dart';
import 'src/perf_report.dart';

const String _topUsage = '''
molia 跨端工具（Linux / macOS / Windows 同一套命令）

用法: dart run tool/agent/cli.dart <命令> [参数]

命令:
  info                      环境信息（平台 / Dart / Flutter / adb / Android CLI）
  deps                      依赖与工具链体检：pub 可解析性、AGP/KGP、工具版本
  size apk [<apk>...]       APK 分组体积与 native 库约束
  perf report [<目录>]      frames 结果汇总成 summary.md
  help [<命令>]             查看总用法或单个命令用法

选项:
  -h, --help                同 help
''';

const String _infoUsage = '''
用法: dart run tool/agent/cli.dart info

只读：打印仓库路径、平台、Dart / Flutter / adb / Android CLI 版本与 SDK 位置。
排查「本机工具链是不是齐」时先跑这个。
''';

const String _depsUsage = '''
用法: dart run tool/agent/cli.dart deps

只读体检，报告写到 \$RUN_DIR/deps-<时间戳>/（默认 \$TMPDIR/molia-agent）：

- summary.txt        每条检查的 ok/fail
- pub-outdated.txt   flutter pub outdated 原始输出
- analyze-suggestions.txt  flutter analyze --suggestions
- gradle-environment.txt   android/gradlew -q buildEnvironment
- android-cli-version.txt  Android CLI -V
''';

const String _sizeUsage = '''
用法: dart run tool/agent/cli.dart size apk [选项] [<apk>...]

不给路径时取 build/app/outputs/flutter-apk/ 下最新的 .apk。

选项:
  --check   校验发布约束（禁止 libmpv / libcnativeapi 等，必需 sqlite3 / quickjs）
  --json    输出 JSON（脚本消费）
''';

const String _perfUsage = '''
用法: dart run tool/agent/cli.dart perf report [<目录>]

把结果目录里的 frames*.jsonl / frames*.log（`molia.frame` 行）整理成
summary.md。不给目录时取 \$RUN_DIR 下最新的 perf-* 目录。
''';

Future<void> main(List<String> args) async {
  final context = ToolContext.create();
  if (args.isEmpty) {
    stderr.write(_topUsage);
    exitCode = 2;
    return;
  }
  if (_wantsHelp(args.first)) {
    stdout.write(args.length > 1 ? _usageFor(args[1]) : _topUsage);
    return;
  }
  final command = args.first;
  final rest = args.sublist(1);
  switch (command) {
    case 'help':
      stdout.write(rest.isEmpty ? _topUsage : _usageFor(rest.first));
    case 'info':
      if (rest.isNotEmpty && _wantsHelp(rest.first))
        return stdout.write(_infoUsage);
      await _runInfo(context);
    case 'deps':
      if (rest.isNotEmpty && _wantsHelp(rest.first))
        return stdout.write(_depsUsage);
      await _runDeps(context);
    case 'size':
      await _runSize(context, rest);
    case 'perf':
      await _runPerf(context, rest);
    default:
      stderr.writeln('[agent] 未知命令：$command（-h 看可用命令）');
      exitCode = 2;
  }
}

bool _wantsHelp(String arg) => arg == '-h' || arg == '--help';

String _usageFor(String command) => switch (command) {
  'info' => _infoUsage,
  'deps' => _depsUsage,
  'size' => _sizeUsage,
  'perf' => _perfUsage,
  'help' => _topUsage,
  _ => '没有命令 `$command` 的用法（-h 看总用法）\n',
};

Future<void> _runInfo(ToolContext context) async {
  stdout.writeln('repo: ${context.repoRoot}');
  stdout.writeln(
    '平台: ${Platform.operatingSystem} ${Platform.version.split(' ').first}',
  );
  stdout.writeln('dart: ${Platform.version}');
  stdout.writeln('RUN_DIR: ${context.runDir}');
  stdout.writeln('Android SDK: ${context.androidSdk}');
  await _printToolVersion(context, 'flutter', context.flutter, const [
    '--version',
  ]);
  await _printToolVersion(context, 'adb', context.adb, const ['version']);
  await _printToolVersion(context, 'Android CLI', context.androidCli, const [
    '-V',
  ]);
}

Future<void> _printToolVersion(
  ToolContext context,
  String label,
  String? executable,
  List<String> versionArgs,
) async {
  if (executable == null) {
    stdout.writeln('$label: 未找到');
    return;
  }
  final outcome = await context.runCapture([
    executable,
    ...versionArgs,
  ], timeout: const Duration(seconds: 60));
  final firstLine = '${outcome.stdout}${outcome.stderr}'
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  stdout.writeln(
    '$label: $executable（${outcome.ok ? firstLine : '执行失败 ${outcome.exitCode}'}）',
  );
}

Future<void> _runDeps(ToolContext context) async {
  final flutter = context.flutter;
  if (flutter == null) context.fail('找不到 flutter（把 Flutter 加进 PATH）');

  final stamp = _stamp();
  final outDir = Directory('${context.runDir}/deps-$stamp')
    ..createSync(recursive: true);
  final summary = StringBuffer();
  context.log('报告目录：${outDir.path}');

  Future<void> record(
    String slug,
    List<String> command, {
    String? workingDirectory,
  }) async {
    context.log('== $slug');
    final outcome = await context.runCapture(
      command,
      workingDirectory: workingDirectory,
      timeout: const Duration(minutes: 15),
    );
    File('${outDir.path}/$slug.txt').writeAsStringSync(
      '\$ ${outcome.printable}\n\n${outcome.stdout}${outcome.stderr}',
    );
    final status = outcome.ok ? 'ok' : 'fail';
    summary.writeln('${slug.padRight(24)}$status');
    stdout.writeln('${slug.padRight(24)}$status');
  }

  await record('pub-outdated', [flutter, 'pub', 'outdated']);

  final analyze = await context.runCapture([
    flutter,
    'analyze',
    '--suggestions',
    '--no-pub',
  ], timeout: const Duration(minutes: 15));
  File('${outDir.path}/analyze-suggestions.txt').writeAsStringSync(
    '\$ ${analyze.printable}\n\n${analyze.stdout}${analyze.stderr}',
  );
  summary.writeln(
    '${'analyze-suggestions'.padRight(24)}${analyze.ok ? 'ok' : 'fail'}',
  );
  stdout.writeln(
    '${'analyze-suggestions'.padRight(24)}${analyze.ok ? 'ok' : 'fail'}',
  );

  // docs 检查仍是 python 实现（迁移中）：有 python3 就跑，没有就跳过并说明。
  final python = context.which('python3') ?? context.which('python');
  if (python == null) {
    summary.writeln(
      '${'check-docs'.padRight(24)}skip（没有 python3，docs 检查尚未迁移到 CLI）',
    );
  } else {
    await record('check-docs', [
      python,
      '${context.repoRoot}/tool/agent/check_docs.py',
      '--toolchain',
    ]);
  }

  final gradlew = File('${context.repoRoot}/android/gradlew');
  if (gradlew.existsSync()) {
    await record('gradle-environment', [
      gradlew.path,
      '-q',
      'buildEnvironment',
    ], workingDirectory: '${context.repoRoot}/android');
  } else {
    summary.writeln(
      '${'gradle-environment'.padRight(24)}skip（没有 android/gradlew）',
    );
  }

  final androidCli = context.androidCli;
  if (androidCli == null) {
    summary.writeln(
      '${'android-cli-version'.padRight(24)}skip（未找到 Android CLI）',
    );
  } else {
    await record('android-cli-version', [androidCli, '-V']);
  }

  File('${outDir.path}/summary.txt').writeAsStringSync(summary.toString());
  context.log('报告已写入：${outDir.path}');
  context.log('先看 summary.txt；失败项在对应 *.txt 里查原始输出。');
}

Future<void> _runSize(ToolContext context, List<String> args) async {
  if (args.isEmpty) {
    stderr.write(_sizeUsage);
    exitCode = 2;
    return;
  }
  if (_wantsHelp(args.first)) return stdout.write(_sizeUsage);
  if (args.first != 'apk') {
    stderr.writeln('[agent] 未知子命令：${args.first}（目前只有 apk）');
    exitCode = 2;
    return;
  }
  args = args.sublist(1);
  var check = false;
  var json = false;
  final paths = <String>[];
  for (final arg in args) {
    switch (arg) {
      case '--check':
        check = true;
      case '--json':
        json = true;
      default:
        if (arg.startsWith('-')) {
          stderr.writeln('[agent] 未知选项：$arg（-h 看用法）');
          exitCode = 2;
          return;
        }
        paths.add(arg);
    }
  }

  final targets = paths.isEmpty ? _latestApkPaths(context) : paths;
  if (targets.isEmpty) {
    stderr.writeln('[agent] 没找到 APK：先 flutter build apk，或显式传路径');
    exitCode = 2;
    return;
  }

  var failed = false;
  for (final path in targets) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('[agent] 文件不存在：$path');
      failed = true;
      continue;
    }
    final report = inspectApk(file);
    if (check) {
      final errors = checkApk(report);
      if (errors.isEmpty) {
        stderr.writeln('[OK] $path: native 库约束通过');
      } else {
        failed = true;
        for (final error in errors) {
          stderr.writeln('[FAIL] $path: $error');
        }
      }
    }
    final text = json ? renderApkJson(report) : renderApkMarkdown(report);
    stdout.write(text.endsWith('\n') ? text : '$text\n');
  }
  if (failed) exitCode = 1;
}

List<String> _latestApkPaths(ToolContext context) {
  final all = <File>[];
  final candidates = [
    '${context.repoRoot}/build/app/outputs/flutter-apk',
    '${context.repoRoot}/build/app/outputs/apk',
  ];
  for (final candidate in candidates) {
    final dir = Directory(candidate);
    if (!dir.existsSync()) continue;
    all.addAll(
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.apk')),
    );
  }
  if (all.isEmpty) return const [];
  all.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
  return [all.first.path];
}

Future<void> _runPerf(ToolContext context, List<String> args) async {
  if (args.isEmpty) {
    stderr.write(_perfUsage);
    exitCode = 2;
    return;
  }
  if (_wantsHelp(args.first)) return stdout.write(_perfUsage);
  if (args.first != 'report') {
    stderr.writeln('[agent] 未知子命令：${args.first}（目前只有 report）');
    exitCode = 2;
    return;
  }
  final rest = args.sublist(1);
  if (rest.isNotEmpty && _wantsHelp(rest.first))
    return stdout.write(_perfUsage);

  final directory = rest.isNotEmpty
      ? Directory(rest.first)
      : _latestPerfDir(context);
  if (directory == null || !directory.existsSync()) {
    stderr.writeln(
      '[agent] 结果目录不存在：${rest.isNotEmpty ? rest.first : '（\$RUN_DIR 下没有 perf-*）'}',
    );
    exitCode = 2;
    return;
  }

  final rows = loadFrameRows(directory);
  if (rows.isEmpty) {
    stderr.writeln(
      '[agent] ${directory.path} 里没有 molia.frame 样本（timeline 结果用 perf.sh 的 timeline_report.py）',
    );
    exitCode = 1;
    return;
  }
  final summary = File('${directory.path}/summary.md')
    ..writeAsStringSync(renderFrameSummary(rows));
  stdout.writeln('${rows.length} 条帧样本 -> ${summary.path}');
}

Directory? _latestPerfDir(ToolContext context) {
  final runDir = Directory(context.runDir);
  if (!runDir.existsSync()) return null;
  final dirs =
      runDir
          .listSync()
          .whereType<Directory>()
          .where(
            (dir) =>
                dir.path.split(Platform.pathSeparator).last.startsWith('perf-'),
          )
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
  return dirs.isEmpty ? null : dirs.first;
}

String _stamp() {
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}';
}
