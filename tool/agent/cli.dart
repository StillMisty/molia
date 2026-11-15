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
import 'src/commands/analyze.dart';
import 'src/commands/app.dart';
import 'src/commands/docs.dart';
import 'src/commands/emu.dart';
import 'src/commands/smoke.dart';
import 'src/commands/win.dart';
import 'src/commands/test.dart';
import 'src/context.dart';
import 'src/data_report.dart';
import 'src/docs_check.dart';
import 'src/perf_report.dart';
import 'src/timeline_report.dart';

const String _topUsage = '''
molia 跨端工具（Linux / macOS / Windows 同一套命令）

用法: dart run tool/agent/cli.dart <命令> [参数]

命令:
  info                      环境信息（平台 / Dart / Flutter / adb / Android CLI）
  deps                      依赖与工具链体检：pub 可解析性、AGP/KGP、工具版本
  analyze [选项]            flutter analyze（默认 --no-pub，--pub 可关闭）
  docs check [--docs|--toolchain]  文档引用 / 工具链一致性（CI 与 pre-commit 用）
  test <平台> [选项]        集成测试：linux / android / all
  smoke linux              启动首帧烟测（真实 main + provider tree）
  app <命令>               run / reload / restart / stop / log / status（--machine 控制通道）
  emu <命令>               start / stop / status（Android 模拟器）
  win <命令>               Windows 采样：mem / scroll / frames / startup（Dart + FFI）
  size apk [<apk>...]       APK 分组体积与 native 库约束
  perf <子命令>             frames / startup / data / cpu / memory / size（后端 perf.sh）
  perf report [<目录>]      frames 结果汇总成 summary.md（本命令为 Dart 实现）
  perf timeline <json>      VM timeline 帧归因（--out 指定 markdown 路径）
  perf home <prefs.json>    固定隔离 HOME 的窗口 bounds（data/cpu 前置）
  startup|cpu|memory|io|seed  采样与数据注入（平台后端：sh / ps1，参数原样透传）
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
      if (rest.isNotEmpty && _wantsHelp(rest.first)) {
        return stdout.write(_infoUsage);
      }
      await _runInfo(context);
    case 'deps':
      if (rest.isNotEmpty && _wantsHelp(rest.first)) {
        return stdout.write(_depsUsage);
      }
      await _runDeps(context);
    case 'analyze':
      await runAnalyze(context, rest);
    case 'docs':
      await runDocs(context, rest);
    case 'test':
      await runTest(context, rest);
    case 'smoke':
      await runSmoke(context, rest);
    case 'app':
      await runApp(context, rest);
    case 'emu':
      await runEmu(context, rest);
    case 'win':
      await runWin(context, rest);
    case 'size':
      await _runSize(context, rest);
    case 'perf':
      if (rest.isEmpty ||
          const {
            'report',
            'timeline',
            'home',
            'data-report',
          }.contains(rest.first)) {
        await _runPerf(context, rest);
      } else {
        await _runBackend(context, 'perf', rest);
      }
    case 'startup':
    case 'cpu':
    case 'memory':
    case 'io':
    case 'seed':
      await _runBackend(context, command, rest);
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

  // 文档 / 工具链一致性：直接调 Dart 实现，不再依赖 Python。
  try {
    final docsCheck = runDocsCheck(
      context.repoRoot,
      docs: false,
      toolchain: true,
    );
    File('${outDir.path}/check-docs.txt').writeAsStringSync(
      docsCheck.ok
          ? 'check_docs: OK\n'
          : '${docsCheck.errors.map((error) => 'ERROR $error').join('\n')}\n\n'
                'check_docs: ${docsCheck.errors.length} 项失败\n',
    );
    final status = docsCheck.ok ? 'ok' : 'fail';
    summary.writeln('${'check-docs'.padRight(24)}$status');
    stdout.writeln('${'check-docs'.padRight(24)}$status');
  } on StateError catch (error) {
    File('${outDir.path}/check-docs.txt')
        .writeAsStringSync('${error.message}\n');
    summary.writeln('${'check-docs'.padRight(24)}fail');
    stdout.writeln('${'check-docs'.padRight(24)}fail');
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
  if (_wantsHelp(args.first)) {
    return stdout.write(_sizeUsage);
  }
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
  if (_wantsHelp(args.first)) {
    return stdout.write(_perfUsage);
  }
  if (args.first == 'timeline') {
    await _runTimeline(args.sublist(1));
    return;
  }
  if (args.first == 'home') {
    _runPerfHome(args.sublist(1));
    return;
  }
  if (args.first == 'data-report') {
    _runDataReport(args.sublist(1));
    return;
  }
  if (args.first != 'report') {
    stderr.writeln('[agent] 未知子命令：${args.first}（report / timeline）');
    exitCode = 2;
    return;
  }
  final rest = args.sublist(1);
  if (rest.isNotEmpty && _wantsHelp(rest.first)) {
    return stdout.write(_perfUsage);
  }

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
      '[agent] ${directory.path} 里没有 molia.frame 样本（timeline 结果用 `perf timeline`）',
    );
    exitCode = 1;
    return;
  }
  final summary = File('${directory.path}/summary.md')
    ..writeAsStringSync(renderFrameSummary(rows));
  stdout.writeln('${rows.length} 条帧样本 -> ${summary.path}');
}

/// 平台后端：采样 / 注入类命令仍由 sh（Linux/macOS）或 ps1（Windows）实现。
///
/// ADR-0031 的分层里，这些命令依赖 /proc、Xvfb、dbus-run-session、adb root
/// 或 Win32 采样，重写成 Dart 只会把同一堆平台假设搬个地方。这里统一的是
/// **入口**：三端都从 cli.dart 进来，由本函数选后端并透传参数与退出码。
Future<void> _runBackend(
  ToolContext context,
  String name,
  List<String> args,
) async {
  if (context.isWindows) {
    // Windows 采样已迁到 Dart + FFI（win 命令）；ps1 只作未覆盖场景的兜底。
    if (name == 'memory') {
      await runWin(context, ['mem', ...args]);
      return;
    }
    if (name == 'startup') {
      await runWin(context, ['startup', ...args]);
      return;
    }
    if (name == 'perf' &&
        args.length >= 2 &&
        args.first == 'frames' &&
        args.contains('--real')) {
      await runWin(context, [
        'frames',
        ...args.where((arg) => arg != '--real'),
      ]);
      return;
    }
    stderr.writeln(
      '[agent] Windows 上还没有 `$name` 的等价实现（见 ADR-0031）：'
      '这一步在 Linux/WSL 侧执行；采样类可用 `win mem|scroll|frames|startup`',
    );
    exitCode = 2;
    return;
  }

  final script = File('${context.repoRoot}/tool/agent/$name.sh');
  if (!script.existsSync()) context.fail('找不到后端脚本：${script.path}');
  final code = await context.runInherit(['bash', script.path, ...args]);
  if (code != 0) exitCode = code;
}

/// `perf home <prefs.json>`：把隔离 HOME 的窗口 bounds 固定成 1440×900。
void _runPerfHome(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      '用法: dart run tool/agent/cli.dart perf home <shared_preferences.json>',
    );
    exitCode = 2;
    return;
  }
  resetPerfWindowBounds(args.first);
}

/// `perf data-report <目录>`：molia.perf 样本 → summary.md。
void _runDataReport(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/agent/cli.dart perf data-report <结果目录>');
    exitCode = 2;
    return;
  }
  final directory = Directory(args.first);
  if (!directory.existsSync()) {
    stderr.writeln('[agent] 目录不存在：${args.first}');
    exitCode = 2;
    return;
  }
  final report = renderDataReport(directory);
  final summary = File('${directory.path}${Platform.pathSeparator}summary.md')
    ..writeAsStringSync(report.markdown);
  if (!report.hasSamples) {
    stderr.writeln('[agent] 没有采到 molia.perf 样本（${directory.path}）');
    exitCode = 1;
    return;
  }
  stdout.write(report.markdown);
  stderr.writeln('[agent] 已写入 ${summary.path}');
}

/// `perf timeline <timeline.json> [--out <summary.md>]`：VM timeline 帧归因。
Future<void> _runTimeline(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      '用法: dart run tool/agent/cli.dart perf timeline <timeline.json> [--out <summary.md>]',
    );
    exitCode = 2;
    return;
  }
  final file = File(args.first);
  if (!file.existsSync()) {
    stderr.writeln('[agent] 文件不存在：${file.path}');
    exitCode = 2;
    return;
  }
  String? out;
  for (var index = 1; index < args.length; index++) {
    if (args[index] == '--out' && index + 1 < args.length) {
      out = args[++index];
      continue;
    }
    stderr.writeln('[agent] 未知参数：${args[index]}');
    exitCode = 2;
    return;
  }

  final report = renderTimelineReport(file);
  if (out != null) {
    File(out).writeAsStringSync(report.markdown);
    if (!report.ok) {
      stderr.writeln('[agent] trace 里没有 $buildEvent 事件；已写出说明到 \$out');
      exitCode = 1;
      return;
    }
    stdout.writeln('timeline 归因 -> $out');
    return;
  }
  stdout.write(report.markdown);
  if (!report.ok) exitCode = 1;
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
