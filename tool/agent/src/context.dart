/// 跨端工具 CLI 的运行时上下文：仓库位置、平台探测、外部进程调用。
///
/// 为什么用 Dart 而不是 bash：Windows 开发机没有 bash（也没有保证有
/// Python），而 Flutter 开发者一定有 Dart。工具只依赖 `dart:io`，因此
/// Linux / macOS / Windows 三端跑的是同一份实现，平台差异收敛在这里。
library;

import 'dart:convert';
import 'dart:io';

/// 一次外部命令的结果（超时说清楚是哪个命令，避免只看 exitCode 猜）。
class CommandOutcome {
  const CommandOutcome({
    required this.command,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
  });

  final List<String> command;
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;

  bool get ok => exitCode == 0 && !timedOut;

  String get printable => command.join(' ');
}

class ToolContext {
  ToolContext._(this.repoRoot);

  /// 仓库根目录（`tool/agent/cli.dart` 向上两级）。
  final String repoRoot;

  static ToolContext create() {
    // Platform.script 在 `dart run tool/agent/cli.dart` 下是绝对 file URI；
    // 用 `..` 推导而不是靠 cwd，保证在任意目录调用都指向同一个仓库。
    final script = Platform.script;
    final scriptPath = script.isScheme('file')
        ? script.toFilePath()
        : File(script.toString()).path;
    final agentDir = File(scriptPath).parent.parent;
    return ToolContext._(agentDir.parent.path);
  }

  bool get isWindows => Platform.isWindows;

  /// 运行产物目录：与 sh 版本同口径（RUN_DIR 可覆盖），不放仓库里。
  String get runDir {
    final override = Platform.environment['RUN_DIR'];
    if (override != null && override.isNotEmpty) {
      return override;
    }
    if (isWindows) {
      final temp = Platform.environment['TEMP'] ?? Platform.environment['TMP'];
      if (temp != null && temp.isNotEmpty) {
        return '$temp${Platform.pathSeparator}molia-agent';
      }
      return 'C:\\Windows\\Temp\\molia-agent';
    }
    final tmp = Platform.environment['TMPDIR'];
    return '${tmp ?? '/tmp'}/molia-agent';
  }

  void log(String message) => stderr.writeln('[agent] $message');

  Never fail(String message) {
    stderr.writeln('[agent] ERROR: $message');
    exit(1);
  }

  /// 在 PATH 里找可执行文件；Windows 需要按 PATHEXT 补扩展名
  /// （`Process.run('flutter')` 自己不会补 `.bat`）。
  String? which(String name) {
    final env = Platform.environment;
    final pathValue = env[isWindows ? 'Path' : 'PATH'] ?? env['PATH'] ?? '';
    final dirs = pathValue.split(isWindows ? ';' : ':');
    final extensions = <String>[
      if (!isWindows) '',
      if (isWindows) ..._windowsExtensions,
    ];
    for (final dir in dirs) {
      if (dir.isEmpty) continue;
      for (final extension in extensions) {
        final candidate = File('$dir${Platform.pathSeparator}$name$extension');
        if (candidate.existsSync()) return candidate.path;
      }
    }
    return null;
  }

  List<String> get _windowsExtensions {
    final pathext = Platform.environment['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD';
    return [
      '',
      ...pathext
          .split(';')
          .where((value) => value.isNotEmpty)
          .map((value) => value.toLowerCase()),
    ];
  }

  /// Android SDK 根目录：与 sh 版同口径，环境变量优先。
  String get androidSdk {
    for (final key in ['ANDROID_SDK_ROOT', 'ANDROID_HOME']) {
      final value = Platform.environment[key];
      if (value != null && value.isNotEmpty) return value;
    }
    final home = Platform.environment[isWindows ? 'USERPROFILE' : 'HOME'] ?? '';
    return '$home${Platform.pathSeparator}Android${Platform.pathSeparator}Sdk';
  }

  String? get adb {
    final executable = isWindows ? 'adb.exe' : 'adb';
    final bundled =
        '$androidSdk${Platform.pathSeparator}platform-tools${Platform.pathSeparator}$executable';
    if (File(bundled).existsSync()) return bundled;
    return which(executable);
  }

  String? get flutter =>
      isWindows ? (which('flutter') ?? which('flutter.bat')) : which('flutter');

  /// Android CLI（官方 agent 工具）：包名 / 安装位置各端不同，允许环境变量覆盖。
  String? get androidCli {
    final override = Platform.environment['ANDROID_CLI'];
    if (override != null && override.isNotEmpty) {
      return File(override).existsSync() ? override : override;
    }
    final direct = which('android');
    if (direct != null) return direct;
    final home = Platform.environment[isWindows ? 'USERPROFILE' : 'HOME'] ?? '';
    final local =
        '$home${Platform.pathSeparator}.local${Platform.pathSeparator}bin${Platform.pathSeparator}${isWindows ? 'android.exe' : 'android'}';
    return File(local).existsSync() ? local : null;
  }

  /// 采集输出（不直通终端）；超时按进程树杀掉，避免 flutter / gradle 残留。
  Future<CommandOutcome> runCapture(
    List<String> command, {
    Duration timeout = const Duration(minutes: 10),
    String? workingDirectory,
  }) async {
    final process = await Process.start(
      command.first,
      command.sublist(1),
      workingDirectory: workingDirectory,
      runInShell: isWindows,
    );
    final out = StringBuffer();
    final err = StringBuffer();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(err.write)
        .asFuture<void>();
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .listen(out.write)
        .asFuture<void>();
    var timedOut = false;
    final exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    await Future.wait([stdoutDone, stderrDone]);
    return CommandOutcome(
      command: command,
      exitCode: exitCode,
      stdout: out.toString(),
      stderr: err.toString(),
      timedOut: timedOut,
    );
  }

  /// 直通 stdio（保留进度条 / 颜色），返回退出码。
  Future<int> runInherit(
    List<String> command, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      command.first,
      command.sublist(1),
      workingDirectory: workingDirectory,
      environment: environment,
      mode: ProcessStartMode.inheritStdio,
      runInShell: isWindows,
    );
    return process.exitCode;
  }

  /// 透传输出同时写日志（`flutter test` / `flutter run` 用）：终端上的进度
  /// 不被吞，失败时又能拿到完整日志。
  Future<int> runTee(
    List<String> command, {
    File? logFile,
    Duration? timeout,
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      command.first,
      command.sublist(1),
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: isWindows,
    );
    final sink = logFile?.openWrite();
    void write(String line) {
      stdout.writeln(line);
      sink?.writeln(line);
    }

    final outDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(write)
        .asFuture<void>();
    final errDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(write)
        .asFuture<void>();

    final exit = await process.exitCode.timeout(
      timeout ?? const Duration(hours: 2),
      onTimeout: () {
        process.kill(ProcessSignal.sigterm);
        Future<void>.delayed(const Duration(seconds: 3))
            .then((_) => process.kill(ProcessSignal.sigkill));
        return 124;
      },
    );
    await Future.wait([outDone, errDone]);
    await sink?.flush();
    await sink?.close();
    return exit;
  }
}
