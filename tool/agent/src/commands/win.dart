/// `win`：Windows 侧的采样与窗口驱动（Dart + FFI）。
///
/// 编排留在 Dart，只把真正需要系统调用的部分交给 [Win32]。
/// 仅 Windows 可用；其它平台直接报错，不做静默降级。
library;

import 'dart:convert';
import 'dart:io';

import '../context.dart';
import '../win32.dart';

Future<void> runWin(ToolContext context, List<String> args) async {
  if (!context.isWindows) {
    stderr.writeln('[agent] `win` 命令只在 Windows 上可用（其它平台用 cli.dart 的对应命令）');
    exitCode = 2;
    return;
  }
  if (args.isEmpty) {
    stderr.write(_usage);
    exitCode = 2;
    return;
  }
  final subcommand = args.first;
  final rest = args.sublist(1);
  switch (subcommand) {
    case 'mem':
      await _memory(context, rest);
    case 'scroll':
      await _scroll(context, rest);
    case 'frames':
      await _frames(context, rest);
    case 'startup':
      await _startup(context, rest);
    default:
      stderr.writeln('[agent] 未知子命令：$subcommand（win -h 看用法）');
      exitCode = 2;
  }
}

const String _usage = '''
用法: dart run tool/agent/cli.dart win <命令> [选项]

命令:
  win mem      托盘内存采样：工作集 / 私有字节 / 提交（idle → browse → playing → tray → restored）
  win scroll   对运行中的窗口发滚轮（激活 + 居中 + 滚轮）
  win frames   真实窗口帧采样：启动 → 空闲 → 滚轮滚动 → 收集 molia.frame
  win startup  启动耗时：release 冷启动 N 次，抓窗口出现时间与 log 里的首帧

通用选项:
  --exe <path>      应用产物路径（默认 build/windows/x64/runner/Release/molia.exe）
  --out-dir <dir>   结果目录（默认 %TEMP%\\molia-perf）
''';

String _defaultExe(ToolContext context) =>
    '${context.repoRoot}\\build\\windows\\x64\\runner\\Release\\molia.exe';

String _exePath(ToolContext context, List<String> args) {
  final value = _option(args, '--exe');
  return value.isEmpty ? _defaultExe(context) : value;
}

String _option(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return '';
  return args[index + 1];
}

String _outDir(ToolContext context, List<String> args) {
  final value = _option(args, '--out-dir');
  if (value.isNotEmpty) return value;
  final temp = Platform.environment['TEMP'] ?? 'C:\\Windows\\Temp';
  return '$temp\\molia-perf';
}

/// 与 ps1 同口径地重置收藏页滚动位置与首页目的地，保证多轮从同一屏开始。
void _resetPrefs() {
  final appData = Platform.environment['APPDATA'];
  if (appData == null) return;
  final file = File('$appData\\top.stillmisty\\molia\\shared_preferences.json');
  if (!file.existsSync()) return;
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, Object?>) return;
    decoded['flutter.favorites_scroll_offsets'] =
        '{"favorites":0.0,"history":0.0,"downloads":0.0}';
    decoded['flutter.shell_home_destination'] = 'favorites';
    file.writeAsStringSync(jsonEncode(decoded));
  } on FormatException {
    // 坏 prefs 不阻塞采样。
  }
}

void _killApp() {
  Process.runSync('taskkill', ['/IM', 'molia.exe', '/F']);
  sleep(const Duration(milliseconds: 300));
}

Future<(Process, int)> _startAndWaitWindow(
  String exe,
  String outDir,
  String tag,
) async {
  final stdoutFile = File('$outDir\\$tag.log')..createSync(recursive: true);
  final stderrFile = File('$outDir\\$tag.err.log');
  final process = await Process.start(
    exe,
    const [],
    workingDirectory: File(exe).parent.path,
  );
  final outSink = stdoutFile.openWrite();
  final errSink = stderrFile.openWrite();
  process.stdout.listen((data) => outSink.add(data));
  process.stderr.listen((data) => errSink.add(data));

  final win32 = Win32.instance;
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    final handle = win32.findMainWindow(process.pid);
    if (handle != null) return (process, handle);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('窗口未出现（$tag）');
}

Future<void> _memory(ToolContext context, List<String> args) async {
  final exe = _exePath(context, args);
  final outDir = _outDir(context, args);
  final idleSeconds = int.tryParse(_option(args, '--idle')) ?? 5;
  final playSeconds = int.tryParse(_option(args, '--play')) ?? 8;
  Directory(outDir).createSync(recursive: true);

  final win32 = Win32.instance;
  final rows = <Map<String, Object?>>[];

  void sample(String state, int pid) {
    try {
      final memory = win32.processMemory(pid);
      rows.add({
        'state': state,
        'ws_mb': memory.workingSetMb,
        'private_mb': memory.privateMb,
        'commit_mb': memory.commitMb,
      });
      stdout.writeln(
        '[mem] ${state.padRight(16)} '
        'memory=${memory.privateMb.toStringAsFixed(1)}MB '
        'commit=${memory.commitMb.toStringAsFixed(1)}MB',
      );
    } on Object catch (error) {
      rows.add({'state': state, 'error': '$error'});
      stdout.writeln('[mem] ${state.padRight(16)} 采样失败：$error');
    }
  }

  _killApp();
  _resetPrefs();
  final (process, handle) = await _startAndWaitWindow(
    exe,
    outDir,
    'memory-release',
  );

  await Future<void>.delayed(Duration(seconds: idleSeconds));
  sample('idle', process.pid);

  win32.activate(handle);
  final rect = win32.windowRect(handle);
  final (cx, cy) = rect.center;
  win32.moveCursor(cx, cy);
  for (var index = 0; index < 80; index++) {
    win32.wheel(-120);
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  await Future<void>.delayed(const Duration(seconds: 2));
  sample('browse', process.pid);

  win32.mediaPlayPause();
  await Future<void>.delayed(Duration(seconds: playSeconds));
  sample('playing', process.pid);

  // WM_SYSCOMMAND + SC_CLOSE：应用会隐藏到托盘；WM_CLOSE 会直接销毁窗口。
  win32.closeToTray(handle);
  await Future<void>.delayed(const Duration(seconds: 3));
  sample('tray+3s', process.pid);
  await Future<void>.delayed(const Duration(seconds: 12));
  sample('tray+15s', process.pid);

  await Process.start(exe, const [], workingDirectory: File(exe).parent.path);
  await Future<void>.delayed(const Duration(seconds: 3));
  sample('restored', process.pid);

  _killApp();
  final jsonl = File('$outDir\\memory.jsonl')
    ..writeAsStringSync('${rows.map(jsonEncode).join('\n')}\n');
  stdout.writeln('[mem] 结果：${jsonl.path}');
}

Future<void> _scroll(ToolContext context, List<String> args) async {
  final steps = int.tryParse(_option(args, '--steps')) ?? 60;
  final delayMs = int.tryParse(_option(args, '--delay-ms')) ?? 25;
  final processes = Process.runSync('tasklist', [
    '/FI',
    'IMAGENAME eq molia.exe',
    '/FO',
    'CSV',
  ]);
  final pid = RegExp(r'"molia\.exe","(\d+)"')
      .firstMatch(processes.stdout.toString())
      ?.group(1);
  if (pid == null) context.fail('molia 未运行');
  final win32 = Win32.instance;
  final handle =
      win32.findMainWindow(int.parse(pid)) ?? context.fail('molia 窗口不存在');
  win32.activate(handle);
  await Future<void>.delayed(const Duration(seconds: 2));
  final (cx, cy) = win32.windowRect(handle).center;
  win32.moveCursor(cx, cy);
  for (var index = 0; index < steps; index++) {
    win32.wheel(-120);
    await Future<void>.delayed(Duration(milliseconds: delayMs));
  }
  stdout.writeln('[scroll] done $steps steps');
}

Future<void> _frames(ToolContext context, List<String> args) async {
  final exe = _exePath(context, args);
  final outDir = _outDir(context, args);
  final idleSeconds = int.tryParse(_option(args, '--idle')) ?? 5;
  final scrollSeconds = int.tryParse(_option(args, '--scroll')) ?? 6;
  final wheelSteps = int.tryParse(_option(args, '--wheel-steps')) ?? 40;
  Directory(outDir).createSync(recursive: true);

  _killApp();
  _resetPrefs();
  final (process, handle) = await _startAndWaitWindow(
    exe,
    outDir,
    'frames-release',
  );
  final win32 = Win32.instance;
  win32.activate(handle);
  await Future<void>.delayed(const Duration(seconds: 2));

  final (cx, cy) = win32.windowRect(handle).center;
  win32.moveCursor(cx, cy);
  await Future<void>.delayed(const Duration(seconds: 2));
  context.log('idle ${idleSeconds}s');
  await Future<void>.delayed(Duration(seconds: idleSeconds));

  context.log('wheel scroll ${scrollSeconds}s（$wheelSteps 步/轮）');
  final deadline = DateTime.now().add(Duration(seconds: scrollSeconds));
  while (DateTime.now().isBefore(deadline)) {
    for (var index = 0; index < wheelSteps; index++) {
      win32.wheel(-120);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  await Future<void>.delayed(const Duration(seconds: 6));
  _killApp();
  await process.exitCode.timeout(
    const Duration(seconds: 10),
    onTimeout: () => -1,
  );

  final log = File('$outDir\\frames-release.log');
  final frames = File('$outDir\\frames.log');
  if (log.existsSync()) {
    final lines = log
        .readAsLinesSync()
        .where((line) => line.contains('molia.frame'))
        .join('\n');
    frames.writeAsStringSync('$lines\n');
    stdout.writeln('[perf] 帧日志：${frames.path}');
  } else {
    stderr.writeln('[agent] 没有找到 ${log.path}');
    exitCode = 1;
  }
}

Future<void> _startup(ToolContext context, List<String> args) async {
  final exe = _exePath(context, args);
  final outDir = _outDir(context, args);
  final runs = int.tryParse(_option(args, '--runs')) ?? 5;
  Directory(outDir).createSync(recursive: true);
  final win32 = Win32.instance;
  final rows = <Map<String, Object?>>[];

  for (var run = 1; run <= runs; run++) {
    _killApp();
    final stopwatch = Stopwatch()..start();
    final stdoutFile = File('$outDir\\startup-run-$run.log')
      ..createSync(recursive: true);
    final process = await Process.start(
      exe,
      const [],
      workingDirectory: File(exe).parent.path,
    );
    final sink = stdoutFile.openWrite();
    process.stdout.listen((data) => sink.add(data));

    int? windowMs;
    final windowDeadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(windowDeadline)) {
      if (win32.findMainWindow(process.pid) != null) {
        windowMs = stopwatch.elapsedMilliseconds;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    int? firstFrameMs;
    final firstDeadline = DateTime.now().add(const Duration(seconds: 20));
    final pattern = RegExp(r'molia\.startup: 首帧：(\d+)ms');
    while (DateTime.now().isBefore(firstDeadline)) {
      final match = pattern.firstMatch(stdoutFile.readAsStringSync());
      if (match != null) {
        firstFrameMs = int.parse(match.group(1)!);
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    stopwatch.stop();
    _killApp();
    await sink.flush();
    await sink.close();

    rows.add({
      'run': run,
      'wall_ms': windowMs,
      'first_frame_ms': firstFrameMs,
      'total_ms': stopwatch.elapsedMilliseconds,
      'log': stdoutFile.path,
    });
    stdout.writeln(
      '[perf] run $run/$runs: wall=${windowMs}ms first_frame=${firstFrameMs}ms',
    );
  }

  final jsonl = File('$outDir\\startup.jsonl')
    ..writeAsStringSync('${rows.map(jsonEncode).join('\n')}\n');
  stdout.writeln('[perf] 结果：${jsonl.path}');
  final samples =
      rows.map((row) => row['first_frame_ms']).whereType<int>().toList()
        ..sort();
  if (samples.isNotEmpty) {
    stdout.writeln(
      '[perf] 首帧中位：${samples[samples.length ~/ 2]}ms（样本 ${samples.length}）',
    );
  }
}
