import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'update_installer_types.dart';

/// 更新安装策略（各平台分支见类文档）。
///
/// - **Android**：下载好的 APK 经 MethodChannel 交给系统安装器
///   （Manifest 已声明 FileProvider 与 REQUEST_INSTALL_PACKAGES）；未授予
///   「安装未知应用」时返回 [InstallOutcome.needPermission]。
/// - **Windows 安装版**（目录里有 Inno 的 `unins000.exe`）：静默运行新版
///   `setup.exe`（`/SILENT /NORESTART /CLOSEAPPLICATIONS`），安装器的 `[Run]`
///   段在完成后拉起应用；调用方收到 [InstallOutcome.restartPending] 后退出进程。
/// - **Windows 便携版 / Linux**：把压缩包解到临时目录，写一个「等主进程退出
///   → 覆盖安装目录 → 重启应用」的助手脚本并 detached 启动；
///   只支持「可写的便携安装目录」，系统包管理器安装（目录不可写）降级为
///   [InstallOutcome.notWritable] 由 UI 引导手动下载。
/// - **iOS / macOS**：不做应用内安装（平台限制），返回
///   [InstallOutcome.unsupported]。
class UpdateInstaller {
  UpdateInstaller({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('top.stillmisty.molia/updater');

  final MethodChannel _channel;
  final Logger _logger = Logger('molia.update_installer');

  /// 当前平台标识与产物架构（清单里 platform / arch 的取值）。
  Future<UpdatePlatformInfo> platformInfo() async {
    if (Platform.isAndroid) {
      final abi = await _safeInvoke<String>('supportedAbi') ?? '';
      return UpdatePlatformInfo(platform: 'android', arch: _androidArch(abi));
    }
    if (Platform.isIOS) {
      return UpdatePlatformInfo(platform: 'ios', arch: _dartArch());
    }
    if (Platform.isWindows) {
      return UpdatePlatformInfo(platform: 'windows', arch: _dartArch());
    }
    if (Platform.isLinux) {
      return UpdatePlatformInfo(platform: 'linux', arch: _dartArch());
    }
    if (Platform.isMacOS) {
      return UpdatePlatformInfo(platform: 'macos', arch: _dartArch());
    }
    return UpdatePlatformInfo(platform: Platform.operatingSystem, arch: 'any');
  }

  /// 是否已允许安装未知来源应用（Android）；其余平台恒为 true。
  Future<bool> canInstallPackages() async {
    if (!Platform.isAndroid) return true;
    return await _safeInvoke<bool>('canInstallPackages') ?? false;
  }

  /// 打开「安装未知应用」系统授权页（仅 Android；其余平台空操作）。
  Future<void> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) return;
    await _safeInvoke<void>('openInstallPermissionSettings');
  }

  /// 本机安装形态偏好的产物类别（清单里可能有多种分发形态）。
  ///
  /// - Android → `apk`；
  /// - Windows 安装版（Inno 的 `unins000.exe` 在应用目录）→ `exe`（安装器）；
  ///   便携版 → `zip`；
  /// - Linux → `tar.gz`。
  Future<String?> preferredArchiveKind() async {
    if (Platform.isAndroid) return 'apk';
    if (Platform.isLinux) return 'tar.gz';
    if (Platform.isWindows) {
      final appDir = File(Platform.resolvedExecutable).parent;
      final innoUninstaller = File(p.join(appDir.path, 'unins000.exe'));
      return innoUninstaller.existsSync() ? 'exe' : 'zip';
    }
    return null;
  }

  /// 安装已下载的产物并尽力重启应用。
  Future<InstallOutcome> installAndRestart({
    required String archivePath,
    required String archiveKind,
  }) async {
    if (Platform.isAndroid) return _installAndroid(archivePath);
    if (Platform.isWindows && archiveKind == 'exe') {
      return _installWindowsSetup(archivePath);
    }
    if (Platform.isWindows) {
      return _installOnDesktop(
        archivePath: archivePath,
        archiveKind: archiveKind,
        windows: true,
      );
    }
    if (Platform.isLinux) {
      return _installOnDesktop(
        archivePath: archivePath,
        archiveKind: archiveKind,
        windows: false,
      );
    }
    return InstallOutcome.unsupported;
  }

  /// Windows 安装版：静默运行新版安装器。
  ///
  /// 安装器（windows/installer/molia.iss）在 `[Run]` 段无条件拉起应用，
  /// 因此静默升级完成后会自动重启；`/CLOSEAPPLICATIONS` 让 Restart Manager
  /// 兜底关闭仍在运行的 molia。
  Future<InstallOutcome> _installWindowsSetup(String setupPath) async {
    final setup = File(setupPath);
    if (!await setup.exists()) {
      _logger.warning('安装器不存在: $setupPath');
      return InstallOutcome.failed;
    }
    try {
      await Process.start(
        setup.path,
        const <String>['/SILENT', '/NORESTART', '/CLOSEAPPLICATIONS'],
        mode: ProcessStartMode.detached,
      );
      return InstallOutcome.restartPending;
    } catch (e) {
      _logger.warning('启动安装器失败: $e');
      return InstallOutcome.failed;
    }
  }

  // ── Android ─────────────────────────────────────────────────────────

  Future<InstallOutcome> _installAndroid(String archivePath) async {
    final String? status;
    try {
      status = await _channel.invokeMethod<String>(
        'installApk',
        <String, Object?>{'path': archivePath},
      );
    } on PlatformException catch (e) {
      _logger.warning('调用系统安装器失败: ${e.code} ${e.message}');
      return InstallOutcome.failed;
    } on MissingPluginException catch (e) {
      _logger.warning('更新通道不可用: $e');
      return InstallOutcome.failed;
    }
    return switch (status) {
      'ok' => InstallOutcome.handedOff,
      'needPermission' => InstallOutcome.needPermission,
      _ => InstallOutcome.failed,
    };
  }

  // ── 桌面（Linux / Windows）──────────────────────────────────────────

  Future<InstallOutcome> _installOnDesktop({
    required String archivePath,
    required String archiveKind,
    required bool windows,
  }) async {
    final archive = File(archivePath);
    if (!await archive.exists()) {
      _logger.warning('安装包不存在: $archivePath');
      return InstallOutcome.failed;
    }

    final exePath = Platform.resolvedExecutable;
    final installDir = File(exePath).parent;
    if (!await _isWritable(installDir)) {
      _logger.info('安装目录不可写，降级为手动更新: ${installDir.path}');
      return InstallOutcome.notWritable;
    }

    final staging = await Directory.systemTemp.createTemp('molia-update-');
    try {
      if (!await _extract(
        archive: archive,
        staging: staging,
        archiveKind: archiveKind,
        windows: windows,
      )) {
        await _deleteQuietly(staging);
        return InstallOutcome.failed;
      }

      final payload = await _resolvePayloadRoot(staging);
      // 压缩包不再需要：助手脚本只负责把 payload 搬到安装目录。
      await _deleteQuietly(archive);

      final script = await _writeHelperScript(
        sourceDir: payload,
        installDir: installDir,
        exePath: exePath,
        windows: windows,
      );
      if (script == null) {
        await _deleteQuietly(payload);
        return InstallOutcome.failed;
      }

      await Process.start(
        windows ? 'cmd' : '/bin/sh',
        windows
            ? <String>['/c', script.path, '$pid', payload.path, installDir.path, exePath]
            : <String>[script.path, '$pid', payload.path, installDir.path, exePath],
        mode: ProcessStartMode.detached,
      );
      return InstallOutcome.restartPending;
    } catch (e) {
      _logger.warning('准备更新失败: $e');
      await _deleteQuietly(staging);
      return InstallOutcome.failed;
    }
  }

  /// 解压到 staging；`tar` 同时支持 tar.gz 与 zip（Windows 10+ 自带 bsdtar），
  /// Linux 的 zip 走 unzip 兜底。
  Future<bool> _extract({
    required File archive,
    required Directory staging,
    required String archiveKind,
    required bool windows,
  }) async {
    final ProcessResult result;
    if (!windows && archiveKind == 'zip') {
      result = await Process.run('unzip', <String>[
        '-q',
        archive.path,
        '-d',
        staging.path,
      ]);
    } else {
      result = await Process.run('tar', <String>[
        '-xf',
        archive.path,
        '-C',
        staging.path,
      ]);
    }
    if (result.exitCode != 0) {
      _logger.warning('解压失败（${result.exitCode}）: ${result.stderr}');
      return false;
    }
    return true;
  }

  /// 发布包顶层是 `molia-<版本>-<平台>/` 单目录时下钻一层。
  Future<Directory> _resolvePayloadRoot(Directory staging) async {
    final entries = await staging.list().toList();
    if (entries.length == 1 && entries.first is Directory) {
      return entries.first as Directory;
    }
    return staging;
  }

  Future<File?> _writeHelperScript({
    required Directory sourceDir,
    required Directory installDir,
    required String exePath,
    required bool windows,
  }) async {
    try {
      final script = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'molia-update-${DateTime.now().millisecondsSinceEpoch}'
        '${windows ? '.bat' : '.sh'}',
      );
      final content = windows
          ? _windowsHelperScript
          : _posixHelperScript;
      await script.writeAsString(content, flush: true);
      return script;
    } catch (e) {
      _logger.warning('写入更新助手脚本失败: $e');
      return null;
    }
  }

  /// 参数：$1 主进程 PID、$2 新版本目录、$3 安装目录、$4 可执行文件。
  static const String _posixHelperScript = r'''#!/bin/sh
# Molia 更新助手：等主进程退出 → 覆盖安装目录 → 重启应用。
pid="$1"; src="$2"; dst="$3"; exe="$4"
i=0
while kill -0 "$pid" 2>/dev/null; do
  i=$((i+1))
  [ "$i" -ge 240 ] && break
  sleep 0.5
done
sleep 0.4
cp -a "$src"/. "$dst"/ 2>/dev/null || cp -R "$src"/. "$dst"/
rm -rf "$src"
"$exe" >/dev/null 2>&1 &
exit 0
''';

  /// 参数：%1 主进程 PID、%2 新版本目录、%3 安装目录、%4 可执行文件。
  static const String _windowsHelperScript = '@echo off\r\n'
      'set "PID=%~1"\r\n'
      'set "SRC=%~2"\r\n'
      'set "DST=%~3"\r\n'
      'set "EXE=%~4"\r\n'
      ':wait\r\n'
      'tasklist /FI "PID eq %PID%" 2>nul | find "%PID%" >nul\r\n'
      'if not errorlevel 1 (\r\n'
      '  timeout /t 1 /nobreak >nul\r\n'
      '  goto wait\r\n'
      ')\r\n'
      'robocopy "%SRC%" "%DST%" /E /NFL /NDL /NJH /NJS >nul\r\n'
      'start "" "%EXE%"\r\n'
      'rmdir /s /q "%SRC%"\r\n'
      'del "%~f0"\r\n';

  Future<bool> _isWritable(Directory dir) async {
    final probe = File(
      '${dir.path}${Platform.pathSeparator}.molia-update-probe',
    );
    try {
      await probe.writeAsString('1', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      await _deleteQuietly(probe);
      return false;
    }
  }

  Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete(recursive: true);
    } catch (_) {
      // 残留清理失败不影响主流程。
    }
  }

  Future<T?> _safeInvoke<T>(String method) async {
    try {
      return await _channel.invokeMethod<T>(method);
    } catch (e) {
      _logger.fine('更新通道调用 $method 失败: $e');
      return null;
    }
  }

  String _androidArch(String abi) {
    final normalized = abi.toLowerCase();
    if (normalized.contains('arm64')) return 'arm64';
    if (normalized.contains('armeabi') || normalized == 'arm') return 'armv7';
    if (normalized.contains('x86_64')) return 'x86_64';
    return 'any';
  }

  String _dartArch() {
    final abi = Abi.current();
    return switch (abi) {
      Abi.androidArm64 ||
      Abi.iosArm64 ||
      Abi.fuchsiaArm64 ||
      Abi.linuxArm64 ||
      Abi.macosArm64 ||
      Abi.windowsArm64 =>
        'arm64',
      Abi.androidArm || Abi.iosArm || Abi.linuxArm => 'armv7',
      Abi.androidX64 ||
      Abi.iosX64 ||
      Abi.fuchsiaX64 ||
      Abi.linuxX64 ||
      Abi.macosX64 ||
      Abi.windowsX64 =>
        'x64',
      _ => 'any',
    };
  }
}
