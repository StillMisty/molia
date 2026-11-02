import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
    : _channel = channel ?? const MethodChannel('top.stillmisty.molia/updater');

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
      await Process.start(setup.path, const <String>[
        '/SILENT',
        '/NORESTART',
        '/CLOSEAPPLICATIONS',
      ], mode: ProcessStartMode.detached);
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
      final logPath = await _installLogPath();

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
        windows ? 'powershell' : '/bin/sh',
        windows
            ? <String>[
                '-NoProfile',
                '-NonInteractive',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                script.path,
                '-TargetPid',
                '$pid',
                '-Source',
                payload.path,
                '-Destination',
                installDir.path,
                '-Executable',
                exePath,
                '-LogPath',
                logPath,
              ]
            : <String>[
                script.path,
                '$pid',
                payload.path,
                installDir.path,
                exePath,
                logPath,
              ],
        // 脚本必须从系统临时目录启动：进程 cwd 若落在安装目录里，替换
        // 脚本就无法删除 / 重命名正在使用的目录。
        workingDirectory: Directory.systemTemp.path,
        mode: ProcessStartMode.detached,
      );
      return InstallOutcome.restartPending;
    } catch (e) {
      _logger.warning('准备更新失败: $e');
      await _deleteQuietly(staging);
      return InstallOutcome.failed;
    }
  }

  /// 安装日志：应用支持目录的 `updates/install.log`；拿不到目录时退回
  /// 系统临时目录（日志只用于排障，不能反过来阻断安装）。
  Future<String> _installLogPath() async {
    Directory dir;
    try {
      final support = await getApplicationSupportDirectory();
      dir = Directory(p.join(support.path, 'updates'));
      await dir.create(recursive: true);
    } catch (_) {
      dir = Directory(p.join(Directory.systemTemp.path, 'molia-updates'));
      try {
        await dir.create(recursive: true);
      } catch (_) {
        // 脚本里还会再尝试创建一次目录。
      }
    }
    return p.join(dir.path, 'install.log');
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
        '${windows ? '.ps1' : '.sh'}',
      );
      final content = windows ? _windowsHelperScript : _posixHelperScript;
      await script.writeAsString(content, flush: true);
      return script;
    } catch (e) {
      _logger.warning('写入更新助手脚本失败: $e');
      return null;
    }
  }

  /// 参数：$1 主进程 PID、$2 新版本目录、$3 安装目录、$4 可执行文件、
  /// $5 日志文件。
  ///
  /// 脚本内容保持纯 ASCII：Linux 用 `/bin/sh`，不依赖应用进程存活。
  static const String _posixHelperScript = r'''#!/bin/sh
# Molia update helper: wait for the app, replace files, restart on success.
pid="$1"; src="$2"; dst="$3"; exe="$4"; log="$5"
backup="${dst}.molia-backup"

mkdir -p "$(dirname "$log")" 2>/dev/null || true
log_line() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$log" 2>/dev/null || true
}

start_exe() {
  candidate="$exe"
  if [ ! -e "$candidate" ] && [ -e "$backup/$(basename "$exe")" ]; then
    candidate="$backup/$(basename "$exe")"
  fi
  "$candidate" >/dev/null 2>&1 &
}

rollback() {
  log_line "update failed: $1; rolling back"
  rm -rf "$dst"
  if [ -e "$dst" ]; then
    log_line "rollback failed: cannot remove install dir"
  elif mv "$backup" "$dst" 2>/dev/null; then
    log_line "rollback completed"
  else
    log_line "rollback failed"
  fi
  start_exe
}

log_line "helper started: pid=$pid"
i=0
while kill -0 "$pid" 2>/dev/null; do
  i=$((i+1))
  if [ "$i" -ge 240 ]; then
    log_line "timeout waiting for pid $pid; abort"
    exit 0
  fi
  sleep 0.5
done
sleep 0.4

src_exe="$src/$(basename "$exe")"
if [ ! -e "$src_exe" ]; then
  log_line "payload missing executable; restarting old app"
  start_exe
  exit 1
fi

rm -rf "$backup"
if ! cp -a "$dst" "$backup" 2>/dev/null; then
  log_line "backup failed; restarting old app"
  start_exe
  exit 1
fi

if ! cp -a "$src"/. "$dst"/ 2>/dev/null; then
  rollback "copy failed"
  exit 1
fi

if [ ! -x "$exe" ]; then
  rollback "executable missing or not executable after copy"
  exit 1
fi

rm -rf "$backup"
rm -rf "$src"
log_line "update completed"
start_exe
exit 0
''';

  /// 参数由 Dart 侧以命名参数传入（-TargetPid / -Source / -Destination /
  /// -Executable / -LogPath）。PowerShell 5.1 按 ANSI 读取无 BOM 脚本，
  /// 所以内容必须保持纯 ASCII。
  static const String _windowsHelperScript = r'''param(
    [Parameter(Mandatory=$true)][int]$TargetPid,
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$Destination,
    [Parameter(Mandatory=$true)][string]$Executable,
    [Parameter(Mandatory=$true)][string]$LogPath
)

$ErrorActionPreference = 'Stop'
$backup = "$Destination.molia-backup"

function Write-Log {
    param([string]$Message)
    try {
        $dir = Split-Path -Parent $LogPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
        Add-Content -LiteralPath $LogPath -Value $line -ErrorAction Stop
    } catch {
    }
}

function Start-App {
    $candidate = $Executable
    if (-not (Test-Path -LiteralPath $candidate)) {
        $backupExe = Join-Path $backup (Split-Path -Leaf $Executable)
        if (Test-Path -LiteralPath $backupExe) {
            $candidate = $backupExe
        }
    }
    try {
        Start-Process -FilePath $candidate -WorkingDirectory (Split-Path -Parent $candidate) -ErrorAction Stop | Out-Null
    } catch {
        Write-Log "restart failed: $($_.Exception.Message)"
    }
}

function Remove-Path-Quiet {
    param([string]$Path)
    try {
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
    } catch {
        Write-Log "remove failed: $Path - $($_.Exception.Message)"
    }
}

function Invoke-Rollback {
    param([string]$Reason)
    Write-Log "update failed: $Reason; rolling back"
    try {
        Remove-Path-Quiet $Destination
        if (Test-Path -LiteralPath $Destination) {
            throw "cannot remove partially updated directory"
        }
        if (Test-Path -LiteralPath $backup) {
            Move-Item -LiteralPath $backup -Destination $Destination -Force -ErrorAction Stop
            Write-Log "rollback completed"
        } else {
            Write-Log "rollback failed: backup missing"
        }
    } catch {
        Write-Log "rollback failed: $($_.Exception.Message)"
    }
    Start-App
}

Write-Log "helper started: pid=$TargetPid source=$Source destination=$Destination"

$deadline = (Get-Date).AddSeconds(120)
while ($true) {
    $running = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
    if ($null -eq $running) {
        break
    }
    if ((Get-Date) -ge $deadline) {
        Write-Log "timeout waiting for pid $TargetPid; abort"
        exit 0
    }
    Start-Sleep -Milliseconds 500
}
Start-Sleep -Milliseconds 400

$sourceExe = Join-Path $Source (Split-Path -Leaf $Executable)
if (-not (Test-Path -LiteralPath $sourceExe)) {
    Write-Log "payload missing executable; restarting old app"
    Start-App
    exit 1
}

# Backup failure must abort before touching the install directory.
if (Test-Path -LiteralPath $backup) {
    try {
        Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Log "remove old backup failed: $($_.Exception.Message); restarting old app"
        Start-App
        exit 1
    }
}
try {
    New-Item -ItemType Directory -Path $backup -Force -ErrorAction Stop | Out-Null
    Get-ChildItem -LiteralPath $Destination -Force | Copy-Item -Destination $backup -Recurse -Force -ErrorAction Stop
} catch {
    Write-Log "backup failed: $($_.Exception.Message); restarting old app"
    Start-App
    exit 1
}

try {
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $Executable)) {
        throw "executable missing after copy: $Executable"
    }
} catch {
    Invoke-Rollback $_.Exception.Message
    exit 1
}

Remove-Path-Quiet $backup
Remove-Path-Quiet $Source
Write-Log "update completed"
Start-App
exit 0
''';

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
      Abi.windowsArm64 => 'arm64',
      Abi.androidArm || Abi.iosArm || Abi.linuxArm => 'armv7',
      Abi.androidX64 ||
      Abi.iosX64 ||
      Abi.fuchsiaX64 ||
      Abi.linuxX64 ||
      Abi.macosX64 ||
      Abi.windowsX64 => 'x64',
      _ => 'any',
    };
  }
}
