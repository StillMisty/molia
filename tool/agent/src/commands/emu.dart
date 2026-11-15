/// `emu`：模拟器生命周期（包装 Android CLI 的 emulator 子命令 + adb）。
///
/// 与 `tool/agent/emu.sh` 同口径：默认 headless、默认 AVD 取 `$AVD_NAME`；
/// 三端都能跑（Android CLI 与 adb 在 Windows / macOS 上同样可用）。
library;

import 'dart:io';

import '../context.dart';
import '../platform.dart';

Future<void> runEmu(ToolContext context, List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(_usage);
    exitCode = 2;
    return;
  }
  final subcommand = args.first;
  final rest = args.sublist(1);
  switch (subcommand) {
    case 'start':
      await _start(context, rest);
    case 'stop':
      await _stop(context, rest);
    case 'status':
      await _status(context);
    default:
      stderr.writeln('[agent] 未知子命令：$subcommand（emu -h 看用法）');
      exitCode = 2;
  }
}

const String _usage = '''
用法: dart run tool/agent/cli.dart emu <命令>

命令:
  emu start [--headless|--window] [--cold]   启动模拟器（默认 headless）
  emu stop [<serial>]                        停止模拟器
  emu status                                 查看 AVD 与设备状态
''';

String _avdName(ToolContext context) {
  final value = Platform.environment['AVD_NAME'];
  return value != null && value.isNotEmpty ? value : 'molia_api37';
}

String _requireAdb(ToolContext context) =>
    context.adb ??
    context.fail('未找到 adb（设 ANDROID_SDK_ROOT，或把 platform-tools 加进 PATH）');

Future<void> _start(ToolContext context, List<String> args) async {
  var headless = true;
  var cold = false;
  for (final arg in args) {
    switch (arg) {
      case '--headless':
        headless = true;
      case '--window':
        headless = false;
      case '--cold':
        cold = true;
      default:
        stderr.writeln('[agent] 未知选项：$arg（emu -h 看用法）');
        exitCode = 2;
        return;
    }
  }

  final adb = _requireAdb(context);
  final androidCli = context.androidCli;
  if (androidCli == null) {
    context.fail('未找到 Android CLI：装官方 CLI（android update / 官方 install.sh）后重试');
  }

  final running = runningEmulator(adb);
  if (running != null) {
    context.log('模拟器已在运行：$running');
    return;
  }

  final command = [
    androidCli,
    'emulator',
    'start',
    if (cold) '--cold',
    if (headless) '--headless',
    _avdName(context),
  ];
  context.log('启动模拟器：${command.join(' ')}（冷启动通常 1-3 分钟）');
  final code = await context.runInherit(command);
  if (code != 0) {
    stderr.writeln('[agent] 模拟器启动失败（exit=$code）');
    exitCode = code;
    return;
  }
  final serial = runningEmulator(adb);
  context.log('模拟器就绪：${serial ?? '（adb 尚未列出，稍等再用 emu status 确认）'}');
}

Future<void> _stop(ToolContext context, List<String> args) async {
  final adb = _requireAdb(context);
  final serial = args.isNotEmpty ? args.first : runningEmulator(adb);
  if (serial == null) {
    context.fail('没有找到运行中的模拟器');
  }

  final androidCli = context.androidCli;
  var stopped = false;
  if (androidCli != null) {
    final code = await context.runInherit([
      androidCli,
      'emulator',
      'stop',
      serial,
    ]);
    stopped = code == 0;
  }
  if (!stopped) {
    context.log('Android CLI 停止失败，退回 adb emu kill');
    await context.runCapture([adb, '-s', serial, 'emu', 'kill']);
  }
  context.log('已停止：$serial');
}

Future<void> _status(ToolContext context) async {
  final adb = _requireAdb(context);
  final androidCli = context.androidCli;
  stdout.writeln('== AVD ==');
  if (androidCli == null) {
    stdout.writeln('（未找到 Android CLI）');
  } else {
    final outcome = await context.runCapture([androidCli, 'emulator', 'list']);
    stdout.write('${outcome.stdout}${outcome.stderr}');
  }
  stdout.writeln('== 设备 ==');
  final devices = await context.runCapture([adb, 'devices']);
  stdout.write('${devices.stdout}${devices.stderr}');

  final serial = runningEmulator(adb);
  if (serial == null) return;
  stdout.writeln('== 启动状态（$serial）==');
  final boot = await context.runCapture([
    adb,
    '-s',
    serial,
    'shell',
    'getprop',
    'sys.boot_completed',
  ]);
  stdout.writeln(boot.stdout.trim());
  final page = await context.runCapture([
    adb,
    '-s',
    serial,
    'shell',
    'getconf',
    'PAGE_SIZE',
  ]);
  stdout.writeln('页大小: ${page.stdout.trim()}');
}
