import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../../data/files/app_data_directory.dart';
import 'foreground_activation.dart';
import 'process_liveness.dart';
import 'single_instance_lock.dart';
import 'window_chrome.dart';

/// Linux / Windows / macOS 桌面：进程级单实例。
///
/// **为什么强制**：桌面窗口应用的第二份进程只会带来重复托盘图标、两份播放
/// 会话与两份设置写入，而再次启动的意图几乎总是「把已有窗口拉到前台」；
/// 因此不做用户开关。
///
/// **机制**：`single_instance.lock` 用 `RandomAccessFile.lock` 抢占（Windows
/// 是 `LockFileEx`，Linux / macOS 是 fcntl），进程退出或崩溃时由 OS 自动
/// 释放，因此不再需要 pid 存活判定、清陈旧锁或删除锁文件。主实例把
/// `{"pid","port"}` 写到 sidecar `single_instance.json`，并监听 loopback；
/// 后来进程读 metadata、请主实例 `show` 后退出。
///
/// **为什么不用 `File.create(exclusive: true)`**：创建与写内容是两步；
/// 第二进程可能在内容写入前读到空文件，把「活锁」误判成陈旧锁并删除，
/// 造成两个 primary。文件锁把「所有权」和「metadata」同步分开，锁冲突本身
/// 就是既有实例存在的证据。
///
/// **原生快速路径**：Windows runner 的命名 mutex、Linux runner 的
/// GApplication 会在 Flutter 引擎启动前退出第二实例，并请主实例显示窗口。
/// 本文件仍是跨会话（同一用户两份桌面会话）与 macOS 直接执行二进制的
/// 最终仲裁；原生快速路径不可用时也回落到这里。
///
/// **主锁路径**：`appDataDirectory()`（Windows = LocalAppData，其余平台 =
/// 应用支持目录）。
///
/// **升级守卫**：Windows 升级时，旧版本仍可能在 `%APPDATA%` 的旧目录持有
/// 一份锁、并正在写旧库。新版本抢新锁之前只读一次旧锁：旧 pid 存活时按
/// secondary 退出（连不上也不冒险 primary），pid 已退出才删除旧锁继续。
/// 这个 guard 不参与新锁生命周期，也不写 legacy mirror 锁；降级场景下新旧
/// 版本各用各的库，不会损坏新库。
///
/// 与 `window_chrome` / `app_tray` 同一约束：`dart:io` 与锁文件协议收在
/// 本文件，其余代码只经 `single_instance.dart` 出口访问。
class SingleInstance {
  SingleInstance._();

  static final Logger _logger = Logger('molia.single_instance');

  static const String _lockFileName = 'single_instance.lock';
  static const String _metadataFileName = SingleInstanceLock.metadataFileName;
  static const String _showCommand = 'show';

  /// 自动化逃生口：`tool/agent/*.sh` 启动的测试 / 开发实例必须能与本机
  /// 开发实例并存（否则集成测试会被单实例逻辑直接退出）。仅测试脚本设置。
  /// Windows / Linux runner 的原生快速路径也读同一环境变量。
  static const String disableEnvKey = 'MOLIA_SINGLE_INSTANCE_DISABLED';

  /// 探测既有实例的连接超时：本机 loopback 正常在毫秒级。
  static const Duration _connectTimeout = Duration(seconds: 1);

  /// 锁冲突后等 metadata 写入 / 等旧实例退出的间隔。
  static const Duration _retryDelay = Duration(milliseconds: 150);

  static ServerSocket? _server;

  /// 主实例持有的锁句柄：必须活到进程退出，不能只靠 GC。
  static RandomAccessFile? _lockHandle;

  /// 与 [WindowChrome.isSupported] 同一平台面（Linux / Windows / macOS）：
  /// 单实例的语义是「请主实例把窗口拉到前台」，窗口能力缺失的平台
  /// （Android / iOS）上放行第二实例比误退出更安全。
  static bool get isSupported => WindowChrome.isSupported;

  /// 抢占单实例锁。
  ///
  /// 返回 [SingleInstanceRole.secondary] 时调用方应退出：此时窗口尚未创建，
  /// 不会闪窗。文件锁 / 目录不可用的异常路径保守返回 primary——单实例是
  /// 体验优化，不能成为启动的前置条件。
  static Future<SingleInstanceRole> acquire() async {
    if (!isSupported) return SingleInstanceRole.primary;
    if (Platform.environment[disableEnvKey] == '1') {
      _logger.info('单实例已由 $disableEnvKey 关闭（测试 / 自动化实例）');
      return SingleInstanceRole.primary;
    }
    // 升级守卫：抢新锁前先确认旧版（Roaming 锁）没有在跑。旧版本仍在写
    // 旧库时绝不能进入 primary 去复制数据库。
    final legacyRole = await _legacyUpgradeGuard();
    if (legacyRole != null) return legacyRole;
    final paths = await _lockPaths();
    if (paths == null) return SingleInstanceRole.primary;

    for (
      var attempt = 1;
      attempt <= SingleInstanceLock.maxAcquireAttempts;
      attempt++
    ) {
      final result = await _tryLock(paths.lockFile);
      if (result.handle != null) {
        return _startPrimary(result.handle, paths);
      }
      if (!result.held) {
        _logger.warning('单实例锁不可用（错误码 ${result.errorCode}），按主实例继续');
        return SingleInstanceRole.primary;
      }

      final existing = await _readMetadata(paths.metadataFile);
      if (existing == null) {
        _logger.fine('单实例锁已被占用，metadata 尚未就绪（第 $attempt 次）');
      } else if (existing.pid == pid) {
        // 调试期热重启（尤其 Windows）：旧 isolate 的锁句柄可能还没释放。
        // 同一进程不可能有第二个实例，按 primary 继续即可。
        _logger.info('单实例：同进程遗留锁（热重启），按主实例继续');
        return _startPrimary(null, paths);
      } else if (isProcessAlive(existing.pid)) {
        final notified = await _notifyExisting(existing);
        _logger.info(
          notified
              ? '已有实例在运行（pid ${existing.pid}），已请它显示窗口'
              : '已有实例在运行（pid ${existing.pid}），但显示请求未送达',
        );
        return SingleInstanceRole.secondary;
      } else {
        _logger.info('单实例：锁进程 ${existing.pid} 已退出，重试抢锁');
      }

      if (attempt < SingleInstanceLock.maxAcquireAttempts) {
        await Future<void>.delayed(_retryDelay);
      }
    }

    // 锁一直被占用，但 metadata 始终不可读：更可能是主实例还在启动。
    // 宁可放弃这次启动，也不要双开。
    _logger.warning('单实例锁持续被占用且无法确认主实例，按 secondary 退出（避免双开）');
    return SingleInstanceRole.secondary;
  }

  /// 释放监听与锁句柄（未持锁时是空操作）。
  ///
  /// **不删除锁文件**：删除 + 重建会让另一个进程锁住旧 inode，而新进程锁住
  /// 新 inode，形成两个 primary。正常退出不需要调用本方法——进程退出时 OS
  /// 会关闭句柄并自动释放锁；它只给测试 / 显式收尾用。
  static Future<void> release() async {
    final server = _server;
    final lockHandle = _lockHandle;
    _server = null;
    _lockHandle = null;
    try {
      await server?.close();
    } catch (_) {
      // 关闭监听失败不影响锁句柄释放。
    }
    try {
      await lockHandle?.close();
    } catch (_) {
      // 句柄可能已随进程退出关闭：忽略。
    }
  }

  /// 成为主实例：监听 loopback 端口并写 metadata。
  ///
  /// [lockHandle] 为 null 只出现在同进程热重启（旧句柄仍被旧 isolate 持有），
  /// 此时仍然要起监听 / 写 metadata，让后来实例能找到本进程。
  static Future<SingleInstanceRole> _startPrimary(
    RandomAccessFile? lockHandle,
    _LockPaths paths,
  ) async {
    _lockHandle = lockHandle;

    var port = 0;
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      port = server.port;
      server.listen(
        _handleConnection,
        onError: (Object error) => _logger.warning('单实例监听出错：$error'),
      );
    } catch (error) {
      // 监听失败仍按主实例继续：metadata 里 port=0，后来实例看到存活 pid
      // 就会退出；启动本身不被单实例阻断。
      _logger.warning('单实例监听启动失败，按主实例继续：$error');
    }

    try {
      await _writeMetadata(paths.metadataFile, pid: pid, port: port);
    } catch (error) {
      _logger.warning('单实例 metadata 写入失败（不影响启动）：$error');
    }

    if (lockHandle == null) {
      _logger.info('单实例：本进程为主实例（pid $pid，端口 $port，热重启复用）');
    } else {
      _logger.info('单实例：本进程为主实例（pid $pid，端口 $port）');
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

  /// 请既有实例显示窗口：先交前台权限（Windows），再连 loopback。
  static Future<bool> _notifyExisting(({int pid, int port}) existing) async {
    if (Platform.isWindows && !allowSetForegroundWindow(existing.pid)) {
      _logger.fine('单实例：AllowSetForegroundWindow(${existing.pid}) 失败');
    }
    if (existing.port <= 0) return false;
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        existing.port,
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

  /// 尝试抢锁：成功返回句柄；失败区分「已被占用」与「锁不可用」。
  static Future<_LockAttempt> _tryLock(File lockFile) async {
    final RandomAccessFile handle;
    try {
      handle = await lockFile.open(mode: FileMode.append);
    } on FileSystemException catch (error) {
      final errorCode = error.osError?.errorCode;
      // POSIX 上 open 的 EACCES 是权限问题（文件可读不可写），不是锁冲突；
      // Windows 的 sharing violation 才表示主实例的句柄拒绝了共享。
      final held =
          Platform.isWindows &&
          SingleInstanceLock.isLockConflict(errorCode, onWindows: true);
      return (handle: null, held: held, errorCode: errorCode);
    } catch (error) {
      _logger.warning('单实例锁打开失败：$error');
      return (handle: null, held: false, errorCode: null);
    }

    try {
      // 只锁 1 字节：锁文件不承载 metadata，范围越小越不容易踩到平台差异。
      await handle.lock(FileLock.exclusive, 0, 1);
      return (handle: handle, held: false, errorCode: null);
    } on FileSystemException catch (error) {
      final errorCode = error.osError?.errorCode;
      final held = SingleInstanceLock.isLockConflict(
        errorCode,
        onWindows: Platform.isWindows,
      );
      try {
        await handle.close();
      } catch (_) {
        // 冲突路径上的句柄关闭失败无需处理。
      }
      return (handle: null, held: held, errorCode: errorCode);
    } catch (error) {
      try {
        await handle.close();
      } catch (_) {
        // 同上。
      }
      _logger.warning('单实例锁失败：$error');
      return (handle: null, held: false, errorCode: null);
    }
  }

  static Future<({int pid, int port})?> _readMetadata(File file) async {
    try {
      return SingleInstanceLock.parse(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeMetadata(
    File file, {
    required int pid,
    required int port,
  }) async {
    await file.writeAsString(
      '${SingleInstanceLock.encode(pid: pid, port: port)}\n',
      flush: true,
    );
  }

  /// 主锁目录：应用数据目录（Windows LocalAppData）。
  @visibleForTesting
  static Future<Directory> lockDirectory() => appDataDirectory();

  /// 旧版 Roaming 锁的一次性升级守卫（仅 Windows 新旧目录不同时生效）。
  ///
  /// 返回 null 表示继续正常抢新锁；返回 secondary 表示旧版本仍在运行，
  /// 本进程应立即退出。旧锁只在这里读取 / 清理，不参与新锁生命周期。
  static Future<SingleInstanceRole?> _legacyUpgradeGuard() async {
    if (!hasSeparateLegacyDirectory) return null;
    try {
      final legacyDirectory = await legacyAppDataDirectory();
      if (legacyDirectory == null) return null;
      final lockDirectory = await SingleInstance.lockDirectory();
      if (p.normalize(p.absolute(legacyDirectory.path)) ==
          p.normalize(p.absolute(lockDirectory.path))) {
        return null;
      }
      final legacyLock = File(p.join(legacyDirectory.path, _lockFileName));
      if (!await legacyLock.exists()) return null;

      final existing = await _readMetadata(legacyLock);
      final readable = existing != null;
      final alive = existing != null && isProcessAlive(existing.pid);
      final connected = alive && await _notifyExisting(existing);
      switch (SingleInstanceLock.decideUpgradeGuard(
        lockExists: true,
        readable: readable,
        alive: alive,
        connected: connected,
      )) {
        case LegacyUpgradeAction.proceed:
          if (readable && !alive) {
            _logger.info('旧版本单实例锁进程 ${existing.pid} 已退出，清理后继续');
            await _removeFile(legacyLock);
          }
          return null;
        case LegacyUpgradeAction.secondary:
          _logger.info('检测到旧版本实例（pid ${existing!.pid}），请它显示窗口后退出');
          return SingleInstanceRole.secondary;
        case LegacyUpgradeAction.secondaryUnresponsive:
          _logger.warning(
            '检测到旧版本锁（pid ${existing!.pid}）但无法连接；'
            '为避免复制正在写入的数据库，本次按 secondary 退出。'
            '请先关闭旧版本再启动。',
          );
          return SingleInstanceRole.secondary;
      }
    } catch (error) {
      // 守卫失败不能阻断启动：最坏情况回到新锁流程。
      _logger.warning('检查旧版本单实例锁失败（继续启动）：$error');
      return null;
    }
  }

  static Future<_LockPaths?> _lockPaths() async {
    try {
      final directory = await lockDirectory();
      await directory.create(recursive: true);
      return (
        lockFile: File(p.join(directory.path, _lockFileName)),
        metadataFile: File(p.join(directory.path, _metadataFileName)),
      );
    } catch (error) {
      _logger.warning('单实例锁文件不可用，按主实例继续：$error');
      return null;
    }
  }

  /// 只用于清理旧版 Roaming 锁；新锁文件永不删除。
  static Future<void> _removeFile(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // 已被对方删除 / 不可删：下次启动再判定。
    }
  }
}

typedef _LockPaths = ({File lockFile, File metadataFile});

typedef _LockAttempt = ({RandomAccessFile? handle, bool held, int? errorCode});
