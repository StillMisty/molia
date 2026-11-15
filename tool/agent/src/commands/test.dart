/// `test`：官方 `flutter test` 集成测试入口（Linux 桌面 / Android 模拟器）。
///
/// 与 `tool/agent/test.sh` 同口径：Linux 默认 headless（xvfb-run），Android
/// 默认取运行中的模拟器；判定只看 flutter test 退出码，失败时回显日志尾部。
library;

import 'dart:async';
import 'dart:io';

import '../context.dart';
import '../platform.dart';

Future<void> runTest(ToolContext context, List<String> args) async {
  if (args.isEmpty) {
    stderr.write(_usage);
    exitCode = 2;
    return;
  }
  final platform = args.first;
  if (!const {'linux', 'android', 'all'}.contains(platform)) {
    stderr.write(_usage);
    exitCode = 2;
    return;
  }

  var file = 'integration_test/lx_engine_integration_test.dart';
  var timeoutSeconds = 0;
  var noPub = false;
  var headless = true;
  String? serial;
  var noUninstall = false;

  for (var index = 1; index < args.length; index++) {
    final arg = args[index];
    switch (arg) {
      case '--file':
        file = _value(args, ++index, '--file');
      case '--timeout':
        timeoutSeconds = int.parse(_value(args, ++index, '--timeout'));
      case '--no-pub':
        noPub = true;
      case '--window':
        headless = false;
      case '--no-uninstall':
        noUninstall = true;
      default:
        if (arg.startsWith('-')) {
          stderr.write(_usage);
          exitCode = 2;
          return;
        }
        if (serial != null) {
          stderr.write(_usage);
          exitCode = 2;
          return;
        }
        serial = arg;
    }
  }

  switch (platform) {
    case 'linux':
      final code = await _runOne(
        context,
        'linux',
        file,
        timeoutSeconds,
        headless: headless,
        noPub: noPub,
        noUninstall: noUninstall,
      );
      if (code != 0) exitCode = code;
    case 'android':
      final code = await _runOne(
        context,
        'android',
        file,
        timeoutSeconds,
        headless: headless,
        serial: serial,
        noPub: noPub,
        noUninstall: noUninstall,
      );
      if (code != 0) exitCode = code;
    case 'all':
      final linuxCode = await _runOne(
        context,
        'linux',
        file,
        timeoutSeconds,
        headless: headless,
        noPub: noPub,
        noUninstall: noUninstall,
      );
      if (linuxCode != 0) {
        exitCode = linuxCode;
        return;
      }
      final androidCode = await _runOne(
        context,
        'android',
        file,
        timeoutSeconds,
        headless: headless,
        serial: serial,
        noPub: noPub,
        noUninstall: noUninstall,
      );
      if (androidCode != 0) exitCode = androidCode;
  }
}

const String _usage = '''
用法: dart run tool/agent/cli.dart test linux|android|all [选项] [<serial>]

选项:
  --file <path>      集成测试文件（默认 integration_test/lx_engine_integration_test.dart）
  --timeout <秒>     墙钟超时（默认 linux 900 / android 1800；Android 首次构建放宽）
  --no-pub           跳过 flutter pub get（仅本地迭代）
  --window           在真实显示上跑（默认 Xvfb；Windows / macOS 无此开关）
  --no-uninstall     Android 跑完保留安装（调试安装态时用）
''';

String _value(List<String> args, int index, String flag) {
  if (index >= args.length) {
    stderr.writeln('[agent] $flag 需要参数');
    exit(2);
  }
  return args[index];
}

Future<int> _runOne(
  ToolContext context,
  String platform,
  String file,
  int timeoutSeconds, {
  required bool headless,
  String? serial,
  required bool noPub,
  required bool noUninstall,
}) async {
  final flutter =
      context.flutter ?? context.fail('找不到 flutter（把 Flutter 加进 PATH）');
  final timeout = timeoutSeconds > 0
      ? timeoutSeconds
      : (platform == 'android' ? 1800 : 900);

  final List<String> prefix;
  late final String device;
  if (platform == 'linux') {
    if (context.isWindows) {
      context.fail(
        'Windows 没有 Linux 桌面目标：用 `test android`，或直接 flutter test -d windows',
      );
    }
    try {
      prefix = displayPrefix(headless: headless, requireDisplay: true);
    } on StateError catch (error) {
      context.fail(error.message);
    }
    device = 'linux';
    if (headless) context.log('headless: xvfb-run -a（不弹窗；--window 可切回真实显示）');
  } else {
    final adb =
        context.adb ??
        context.fail('未找到 adb（设 ANDROID_SDK_ROOT，或把 platform-tools 加进 PATH）');
    final resolved = serial ?? runningEmulator(adb);
    if (resolved == null) {
      context.fail('没有运行中的模拟器（也未指定 serial）：先执行 `... emu start`');
    }
    device = resolved;
    context.log('等待设备 $device 就绪');
    final ready = await _waitForDevice(
      context,
      adb,
      device,
      const Duration(seconds: 120),
    );
    if (!ready) context.fail('等待设备 $device 超时');
    prefix = const [];
  }

  final command = <String>[
    ...prefix,
    flutter,
    'test',
    file,
    '-d',
    device,
    if (!stdout.hasTerminal) ...['-r', 'expanded'],
    if (noPub) '--no-pub',
    if (noUninstall) '--no-uninstall',
  ];

  final logFile = File('${context.runDir}/it-$platform-${_stamp()}.log')
    ..createSync(recursive: true);
  context.log('运行: ${command.join(' ')}');
  context.log('日志: ${logFile.path}');

  var code = await context.runTee(
    command,
    logFile: logFile,
    timeout: Duration(seconds: timeout),
    environment: childEnvironment(),
  );

  if (code != 0 && platform == 'linux') {
    // 桌面测试 App 是 flutter test 的子进程，异常路径可能残留并吊住日志管道；
    // 正常退出时它已 tearDownAll exit(0)，这里不按名字清扫，避免误杀手工实例。
    _killApp();
  }

  if (code == 124) {
    context.log('墙钟超时（${timeout}s）被终止；Android 首次 Gradle/冷启动请加 --timeout');
    _tail(logFile, 40);
  } else if (code != 0) {
    context.log('测试失败（exit=$code），日志尾部：');
    _tail(logFile, 40);
  } else {
    context.log('测试通过（$platform，日志: ${logFile.path}）');
  }
  return code;
}

Future<bool> _waitForDevice(
  ToolContext context,
  String adb,
  String serial,
  Duration timeout,
) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    final outcome = await context.runCapture([adb, '-s', serial, 'get-state']);
    if (outcome.stdout.trim() == 'device') return true;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  return false;
}

void _killApp() {
  final binary = Platform.environment['APP_BINARY'] ?? 'molia';
  Process.runSync('pkill', ['-x', binary], runInShell: !Platform.isWindows);
}

void _tail(File file, int lines) {
  if (!file.existsSync()) return;
  final content = file.readAsLinesSync();
  final start = content.length > lines ? content.length - lines : 0;
  for (final line in content.sublist(start)) {
    stderr.writeln(line);
  }
}

String _stamp() {
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
}
