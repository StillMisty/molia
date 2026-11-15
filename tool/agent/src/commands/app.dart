/// `app`：后台应用会话（前台 supervisor + 本地控制通道）。
///
/// 为什么不用信号：Linux 上可以给 `flutter run` 发 SIGUSR1/2 做热重载，但
/// Windows 没有这些信号。这里统一走官方的 `flutter run --machine` 协议——
/// 控制通道是本机 TCP（127.0.0.1 随机端口），三端行为一致。
///
/// 会话信息写入 `$RUN_DIR/app-session.json`，日志写 `$RUN_DIR/flutter-run.log`
/// （与 `tool/agent/app.sh` 共用路径，迁移期两套不打架）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../context.dart';
import '../platform.dart';

Future<void> runApp(ToolContext context, List<String> args) async {
  if (args.isEmpty) {
    stderr.write(_usage);
    exitCode = 2;
    return;
  }
  final subcommand = args.first;
  final rest = args.sublist(1);
  switch (subcommand) {
    case 'run':
      await _run(context, rest);
    case 'reload':
    case 'restart':
      await _control(context, subcommand);
    case 'stop':
      await _stop(context);
    case 'log':
      _log(context, rest);
    case 'status':
      _status(context);
    default:
      stderr.writeln('[agent] 未知子命令：$subcommand（app -h 看用法）');
      exitCode = 2;
  }
}

const String _usage = '''
用法: dart run tool/agent/cli.dart app <命令>

命令:
  app run [-d <device>] [--headless] [--timeout <秒>] [--quiet]
                          前台 supervisor：启动 flutter run --machine 并暴露控制通道
  app reload              热重载（等同终端里按 r）
  app restart             热重启（等同终端里按 R）
  app stop                退出会话并停掉应用
  app log [N]             查看日志（默认最后 40 行）
  app status              查看会话状态

说明:
  - `app run` 是前台进程：要后台跑就自己 nohup / 分屏，或继续用 app.sh（Linux）；
  - 控制通道是本机 TCP，Windows / macOS / Linux 一致，不依赖 SIGUSR1/2。
''';

File _sessionFile(ToolContext context) =>
    File('${context.runDir}/app-session.json');

File _logFile(ToolContext context) => File('${context.runDir}/flutter-run.log');

class _Session {
  _Session({
    required this.pid,
    required this.port,
    required this.device,
    required this.startedAt,
  });

  final int pid;
  final int port;
  final String device;
  final DateTime startedAt;

  Map<String, Object?> toJson() => {
    'pid': pid,
    'port': port,
    'device': device,
    'startedAt': startedAt.toIso8601String(),
  };

  static _Session? read(ToolContext context) {
    final file = _sessionFile(context);
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      return _Session(
        pid: json['pid'] as int,
        port: json['port'] as int,
        device: json['device'] as String,
        startedAt: DateTime.parse(json['startedAt'] as String),
      );
    } on Object {
      return null;
    }
  }
}

String _resolveDevice(ToolContext context, List<String> rest) {
  String? device;
  for (var index = 0; index < rest.length; index++) {
    final arg = rest[index];
    if (arg == '-d' || arg == '--device') {
      if (index + 1 >= rest.length) context.fail('$arg 需要参数');
      device = rest[++index];
    }
  }
  final fromEnv = Platform.environment['DEVICE_ID'];
  if (device != null && device.isNotEmpty) return device;
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  final adb = context.adb;
  if (adb != null) {
    final emulator = runningEmulator(adb);
    if (emulator != null) return emulator;
  }
  if (Platform.isLinux) return 'linux';
  context.fail('无法确定设备：用 -d <device> 指定（flutter devices 查看）');
}

Future<void> _run(ToolContext context, List<String> rest) async {
  final flutter =
      context.flutter ?? context.fail('找不到 flutter（把 Flutter 加进 PATH）');
  final quiet = rest.contains('--quiet');
  var headless = true;
  var timeoutSeconds = 300;
  for (var index = 0; index < rest.length; index++) {
    switch (rest[index]) {
      case '--headless':
        headless = true;
      case '--window':
        headless = false;
      case '--timeout':
        if (index + 1 >= rest.length) context.fail('--timeout 需要参数');
        timeoutSeconds = int.parse(rest[++index]);
    }
  }

  final device = _resolveDevice(context, rest);
  final existing = _Session.read(context);
  if (existing != null && await _alive(existing)) {
    context.fail(
      '已有会话在跑（pid ${existing.pid}，设备 ${existing.device}）：先 app stop',
    );
  }

  var prefix = const <String>[];
  if (device == 'linux') {
    try {
      prefix = displayPrefix(headless: headless, requireDisplay: true);
    } on StateError catch (error) {
      context.fail(error.message);
    }
  }
  final logFile = _logFile(context)..createSync(recursive: true);
  if (logFile.existsSync()) logFile.writeAsStringSync('');

  var command = [...prefix, flutter, 'run', '-d', device, '--machine'];
  // Linux 上让整棵进程树自成一个会话/进程组：停止时按组发信号，应用子进程
  // 不会因为只杀掉 flutter 包装脚本而继续持有 stdio（那会让 supervisor 挂住）。
  if (Platform.isLinux) {
    command = ['setsid', ...command];
  }
  context.log('启动：${command.join(' ')}');
  final process = await Process.start(
    command.first,
    command.sublist(1),
    environment: childEnvironment(),
    runInShell: context.isWindows,
  );

  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final session = _Session(
    pid: process.pid,
    port: server.port,
    device: device,
    startedAt: DateTime.now(),
  );
  _sessionFile(context).writeAsStringSync(jsonEncode(session.toJson()));

  final sink = logFile.openWrite();
  var requestId = 100;
  var ready = false;

  void send(String method) {
    process.stdin.writeln(jsonEncode({'id': requestId++, 'method': method}));
  }

  void writeLog(String line) {
    sink.writeln(line);
    if (!quiet) stdout.writeln(line);
  }

  final stdoutDone = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        writeLog(line);
        final event = _eventOf(line);
        switch (event) {
          case 'app.started':
            ready = true;
            context.log('应用已启动（设备 $device）');
          case 'app.stop':
          case 'app.stopped':
            context.log('应用已退出');
        }
      })
      .asFuture<void>();

  final stderrDone = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(writeLog)
      .asFuture<void>();

  server.listen((socket) {
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          switch (line.trim()) {
            case 'reload':
              send('app.reload');
              socket.writeln('ok');
            case 'restart':
              send('app.restart');
              socket.writeln('ok');
            case 'stop':
              send('app.stop');
              socket.writeln('ok');
              unawaited(_terminate(process, device));
            default:
              socket.writeln('unknown');
          }
        });
  });

  // 启动阶段超时：flutter run 迟迟不 ready 通常意味着构建失败 / 设备没插好。
  // 计时器要显式取消，否则它会撑住事件循环，supervisor 在本该退出时挂着。
  final readyTimer = Timer(Duration(seconds: timeoutSeconds), () {
    if (!ready) {
      context.log('等待 app.started 超时（${timeoutSeconds}s）；看日志：${logFile.path}');
    }
  });

  final code = await process.exitCode;
  readyTimer.cancel();
  await Future.wait([stdoutDone, stderrDone]);
  await sink.flush();
  await sink.close();
  await server.close();
  if (_sessionFile(context).existsSync()) _sessionFile(context).deleteSync();
  context.log('会话结束（exit=$code）');
  if (code != 0) {
    // 被信号结束时 exitCode 是负数；同时硬退出，避免残留的 fd / 监听收不掉
    // 让 supervisor 在本该结束时挂在事件循环里。
    exit(code > 0 ? code : 1);
  }
}

/// 优雅停止：先让 flutter 自己收尾，超时再按平台结束整棵进程树。
///
/// `flutter` 是启动脚本，SIGTERM 只打到脚本本身，真正的 flutter_tools 与
/// 应用进程会残留并继续持有 stdio；按进程组（Linux）/ `taskkill /T`
/// （Windows）/ 命令行精确匹配（macOS）兜底，不用通配杀。
Future<void> _terminate(Process process, String device) async {
  // app.stop 只停应用，flutter run 仍会挂着等下一帧；直接发 TERM 让它收尾。
  _signalTree(process.pid, 'TERM');
  final exit = await process.exitCode.timeout(
    const Duration(seconds: 5),
    onTimeout: () => -1,
  );
  if (exit != -1) return;
  _signalTree(process.pid, 'KILL');
  if (Platform.isLinux) return;
  if (Platform.isWindows) {
    Process.runSync('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
    return;
  }
  Process.runSync('pkill', ['-f', 'flutter_tools.snapshot run -d $device']);
  process.kill(ProcessSignal.sigkill);
}

void _signalTree(int pid, String signal) {
  if (Platform.isLinux) {
    // setsid 之后 pid 即进程组组长，负号表示整个组。
    Process.runSync('kill', ['-$signal', '--', '-$pid']);
    return;
  }
  Process.killPid(
    pid,
    signal == 'KILL' ? ProcessSignal.sigkill : ProcessSignal.sigterm,
  );
}

String? _eventOf(String line) {
  if (!line.startsWith('{')) return null;
  try {
    final json = jsonDecode(line);
    if (json is Map && json['event'] is String) return json['event'] as String;
  } on FormatException {
    return null;
  }
  return null;
}

Future<void> _control(ToolContext context, String method) async {
  final session = _Session.read(context);
  if (session == null) {
    context.fail('没有运行中的会话：先 `app run`');
  }
  final response = await _sendCommand(session, method);
  if (response == null) {
    context.fail('控制通道无响应（pid ${session.pid}）：会话可能已退出，先 app stop/status');
  }
  stdout.writeln('$method: $response');
}

Future<void> _stop(ToolContext context) async {
  final session = _Session.read(context);
  if (session == null) {
    context.log('没有会话在跑');
    return;
  }
  final response = await _sendCommand(session, 'stop');
  if (response == null) {
    context.log('控制通道无响应，按 pid 结束：${session.pid}');
    try {
      Process.killPid(session.pid);
    } on Object {
      context.log('pid 已退出');
    }
  } else {
    context.log('已请求停止（pid ${session.pid}）');
  }
  if (_sessionFile(context).existsSync()) _sessionFile(context).deleteSync();
}

Future<String?> _sendCommand(_Session session, String command) async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      session.port,
      timeout: const Duration(seconds: 5),
    );
    socket.writeln(command);
    final reply = await socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 5));
    // destroy 而不是 close：只读了第一行就关，close 会等对端收尾而挂住。
    socket.destroy();
    return reply;
  } on Object {
    return null;
  }
}

void _log(ToolContext context, List<String> rest) {
  final file = _logFile(context);
  if (!file.existsSync()) {
    stderr.writeln('[agent] 还没有日志：${file.path}');
    exitCode = 1;
    return;
  }
  final lines = rest.isNotEmpty ? int.tryParse(rest.first) ?? 40 : 40;
  final content = file.readAsLinesSync();
  final start = content.length > lines ? content.length - lines : 0;
  for (final line in content.sublist(start)) {
    stdout.writeln(line);
  }
}

Future<void> _status(ToolContext context) async {
  final session = _Session.read(context);
  if (session == null) {
    stdout.writeln('没有运行中的会话（${context.runDir}/app-session.json 不存在）');
    return;
  }
  final alive = await _alive(session);
  stdout.writeln('设备: ${session.device}');
  stdout.writeln('pid: ${session.pid}（${alive ? '运行中' : '已退出，可 app stop 清理'}）');
  stdout.writeln('控制端口: ${session.port}');
  stdout.writeln('启动时间: ${session.startedAt.toIso8601String()}');
}

Future<bool> _alive(_Session session) async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      session.port,
      timeout: const Duration(seconds: 1),
    );
    socket.destroy();
    return true;
  } on Object {
    return false;
  }
}
