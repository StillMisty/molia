/// `smoke`：启动首帧烟测（真实 main() + provider tree）。
///
/// `flutter test` / 集成测试都不跑 `main()`：runApp 之前的 Provider 校验、
/// 平台初始化异常会让窗口一直黑屏，但单测全绿。本命令只关心日志里出现
/// `molia.startup: 首帧`，并在首帧前把 Unhandled Exception 判成失败。
library;

import 'dart:async';
import 'dart:io';

import '../context.dart';

Future<void> runSmoke(ToolContext context, List<String> args) async {
  if (args.isEmpty) {
    stderr.write(_usage);
    exitCode = 2;
    return;
  }
  if (args.first != 'linux') {
    stderr.write(_usage);
    exitCode = 2;
    return;
  }
  var timeoutSeconds = 120;
  for (var index = 1; index < args.length; index++) {
    if (args[index] == '--timeout') {
      if (index + 1 >= args.length) context.fail('--timeout 需要参数');
      timeoutSeconds = int.parse(args[++index]);
      continue;
    }
    stderr.write(_usage);
    exitCode = 2;
    return;
  }

  final logFile = File('${context.runDir}/flutter-run.log');
  // 干净实例：旧会话会让 `app run` 直接拒绝启动。
  await _stopExisting(context);
  if (logFile.existsSync()) logFile.deleteSync();

  context.log('启动真实应用（Xvfb + 软件 GL），等待首帧…');
  final runner = await Process.start(
    Platform.resolvedExecutable,
    [
      Platform.script.toFilePath(),
      'app',
      'run',
      '-d',
      'linux',
      '--headless',
      '--quiet',
      '--timeout',
      '300',
    ],
    environment: {
      ...Platform.environment,
      'LIBGL_ALWAYS_SOFTWARE': '1',
      'XVFBARGS': '-screen 0 1920x1080x24',
    },
  );

  final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));
  var firstFrame = false;
  while (DateTime.now().isBefore(deadline)) {
    if (logFile.existsSync() &&
        logFile.readAsStringSync().contains('molia.startup: 首帧')) {
      firstFrame = true;
      break;
    }
    final fatal = _fatalException(logFile);
    if (fatal != null) {
      context.log('首帧前出现 Unhandled Exception：');
      stderr.writeln(fatal);
      _tail(logFile, 40);
      break;
    }
    if (await runner.exitCode.timeout(
          const Duration(milliseconds: 200),
          onTimeout: () => -1,
        ) !=
        -1) {
      context.log('应用在首帧前退出；日志尾部：');
      _tail(logFile, 60);
      break;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }

  await _stopExisting(context);
  if (firstFrame) {
    final line = logFile.readAsLinesSync().lastWhere(
      (item) => item.contains('molia.startup: 首帧'),
      orElse: () => '',
    );
    context.log('首帧 OK：$line');
    return;
  }
  context.log('等待首帧超时（${timeoutSeconds}s）或启动失败');
  exitCode = 1;
}

const String _usage = '''
用法: dart run tool/agent/cli.dart smoke linux [--timeout <秒>]

只支持 linux 桌面（无头 Xvfb）；Android 启动由 test android / emu 覆盖。
''';

/// 首帧前的 Unhandled Exception 视为失败；DBus 服务缺失这类平台告警是
/// 已知无害项，排除掉。
String? _fatalException(File logFile) {
  if (!logFile.existsSync()) return null;
  for (final line in logFile.readAsLinesSync()) {
    if (line.contains('Unhandled Exception') &&
        !line.contains('DBus.Error.ServiceUnknown')) {
      return line;
    }
  }
  return null;
}

Future<void> _stopExisting(ToolContext context) async {
  final result = await Process.run(Platform.resolvedExecutable, [
    Platform.script.toFilePath(),
    'app',
    'stop',
  ]);
  if (result.exitCode != 0) {
    // 没有会话是正常情况。
    return;
  }
}

void _tail(File file, int lines) {
  if (!file.existsSync()) return;
  final content = file.readAsLinesSync();
  final start = content.length > lines ? content.length - lines : 0;
  for (final line in content.sublist(start)) {
    stderr.writeln(line);
  }
}
