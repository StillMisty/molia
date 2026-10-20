import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'process_liveness.dart';
import 'single_instance_lock.dart';
import 'window_chrome.dart';

/// Linux / Windows / macOS 桌面：进程级单实例。
///
/// **为什么强制**：桌面窗口应用的第二份进程只会带来重复托盘图标、两份播放
/// 会话与两份设置写入，而再次启动的意图几乎总是「把已有窗口拉到前台」；
/// 因此不做用户开关。
///
/// 机制（纯 `dart:io`，不引额外依赖）：应用支持目录下的锁文件
/// （`single_instance.lock`，内容 `{"pid":...,"port":...}`）用
/// `File.create(exclusive: true)` 原子抢占；主实例监听 loopback 端口，
/// 后来进程连上后发一行 `show` 请它显示窗口，然后自己退出。探测不到既有
/// 实例（崩溃残留的陈旧锁）时清掉重抢；重试耗尽保守按主实例继续。
///
/// 与 `window_chrome` / `app_tray` 同一约束：`dart:io` 与锁文件协议收在
/// 本文件，其余代码只经 `single_instance.dart` 出口访问。
class SingleInstance {
  SingleInstance._();

  static final Logger _logger = Logger('molia.single_instance');

  static const String _lockFileName = 'single_instance.lock';
  static const String _showCommand = 'show';

  /// 自动化逃生口：`tool/agent/*.sh` 启动的测试 / 开发实例必须能与本机
  /// 开发实例并存（否则集成测试会被单实例逻辑直接退出）。仅测试脚本设置。
  static const String disableEnvKey = 'MOLIA_SINGLE_INSTANCE_DISABLED';

  /// 探测既有实例的连接超时：本机 loopback 正常在毫秒级，2s 已很宽松。
  static const Duration _connectTimeout = Duration(seconds: 2);

  /// 清理陈旧锁后的重抢间隔（等对方完全退出 / 文件系统回收）。
  static const Duration _retryDelay = Duration(milliseconds: 300);

  static ServerSocket? _server;
  static File? _lockFile;

  /// 与 [WindowChrome.isSupported] 同一平台面（Linux / Windows）：
  /// 单实例的语义是「请主实例把窗口拉到前台」，窗口能力缺失的平台
  /// （如 macOS 目前走 stub，`show()` 是空操作）上放行第二实例比误退出更安全。
  static bool get isSupported => WindowChrome.isSupported;

  /// 抢占单实例锁。
  ///
  /// 返回 [SingleInstanceRole.secondary] 时调用方应立即退出：此时窗口尚未
  /// 创建，不会闪窗。任何异常路径都保守返回 primary——单实例是体验优化，
  /// 不能成为启动的前置条件。
  static Future<SingleInstanceRole> acquire() async {
    if (!isSupported) return SingleInstanceRole.primary;
    if (Platform.environment[disableEnvKey] == '1') {
      _logger.info('单实例已由 $disableEnvKey 关闭（测试 / 自动化实例）');
      return SingleInstanceRole.primary;
    }
    final lockFile = await _lockFileHandle();
    if (lockFile == null) return SingleInstanceRole.primary;

    for (var attempt = 1;
        attempt <= SingleInstanceLock.maxAcquireAttempts;
        attempt++) {
      if (await _tryCreateExclusive(lockFile)) {
        return _startPrimary(lockFile);
      }
      final existing = await _readLock(lockFile);
      final alive = existing != null && isProcessAlive(existing.pid);
      final connected = alive && await _notifyExisting(existing.port);
      switch (SingleInstanceLock.decide(
        connected: connected,
        alive: alive,
        attempt: attempt,
      )) {
        case SingleInstanceAction.secondary:
          _logger.info('已有实例在运行（pid ${existing!.pid}），请它显示窗口');
          return SingleInstanceRole.secondary;
        case SingleInstanceAction.retryAcquire:
          // pid 已退出时无需等连接超时：清锁后立即重抢（强杀 / 更新后常见）。
          if (existing != null && !alive) {
            _logger.info('单实例：锁进程 ${existing.pid} 已退出，立即重抢');
          }
          await _removeLockFile(lockFile);
          if (alive) await Future<void>.delayed(_retryDelay);
        case SingleInstanceAction.fallbackPrimary:
          // 重试耗尽：宁可多开一个窗口，也不要卡死启动。
          _logger.warning('单实例锁重试耗尽，按主实例继续（可能多开一个窗口）');
          return _startPrimary(lockFile);
      }
    }
    return _startPrimary(lockFile);
  }

  /// 退出前尽力释放：关闭监听并删除锁文件（未持锁时是空操作）。
  ///
  /// 正常退出路径（`WindowChrome.quit`）会调用；进程被强杀留下的锁由下次
  /// 启动按陈旧锁清理，不依赖信号处理器（信号处理在 Flutter 桌面不可靠）。
  static Future<void> release() async {
    final server = _server;
    final lockFile = _lockFile;
    _server = null;
    _lockFile = null;
    try {
      await server?.close();
    } catch (_) {
      // 关闭监听失败不影响退出：锁文件删除仍会尝试。
    }
    if (lockFile != null) await _removeLockFile(lockFile);
  }

  /// 成为主实例：监听 loopback 端口并把端口写回锁文件。
  static Future<SingleInstanceRole> _startPrimary(File lockFile) async {
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      _lockFile = lockFile;
      server.listen(
        _handleConnection,
        onError: (Object error) => _logger.warning('单实例监听出错：$error'),
      );
      // 端口只有 bind 之后才知道：文件先由独占创建占位，内容稍后写入；
      // 恰好读到半写内容的并发启动会按陈旧锁清理重试，不会卡住。
      await lockFile.writeAsString(
        SingleInstanceLock.encode(pid: pid, port: server.port),
      );
      _logger.info('单实例：本进程为主实例（pid $pid，端口 ${server.port}）');
    } catch (error) {
      // 监听 / 写锁失败仍按主实例继续：不做启动阻塞。
      _logger.warning('单实例监听启动失败，按主实例继续：$error');
    }
    return SingleInstanceRole.primary;
  }

  /// 处理后来实例的连接：收到 `show` 就显示并聚焦主窗口。
  static void _handleConnection(Socket socket) {
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        if (line.trim() == _showCommand) unawaited(_showWindow());
      },
      onDone: socket.destroy,
      onError: (Object _) => socket.destroy(),
      cancelOnError: true,
    );
  }

  static Future<void> _showWindow() async {
    try {
      await WindowChrome.show();
    } catch (error) {
      // 主实例可能还在启动（插件未就绪）：请求丢失无妨，它自己会显示窗口。
      _logger.warning('响应单实例显示请求失败：$error');
    }
  }

  /// 请既有实例显示窗口：连得上并发出命令才算「对方活着」。
  static Future<bool> _notifyExisting(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: _connectTimeout,
      );
      socket.write('$_showCommand\n');
      await socket.flush();
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 独占创建（`O_EXCL`）：成功 = 本进程抢到锁；失败 = 已存在（或目录不可写）。
  static Future<bool> _tryCreateExclusive(File lockFile) async {
    try {
      await lockFile.create(exclusive: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static Future<({int pid, int port})?> _readLock(File lockFile) async {
    try {
      return SingleInstanceLock.parse(await lockFile.readAsString());
    } catch (_) {
      return null;
    }
  }

  static Future<void> _removeLockFile(File lockFile) async {
    try {
      await lockFile.delete();
    } catch (_) {
      // 已被对方删除 / 不可删：重抢时会再判定一次。
    }
  }

  static Future<File?> _lockFileHandle() async {
    try {
      final directory = await getApplicationSupportDirectory();
      await directory.create(recursive: true);
      return File(p.join(directory.path, _lockFileName));
    } catch (error) {
      _logger.warning('单实例锁文件不可用，按主实例继续：$error');
      return null;
    }
  }
}
