import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../domain/models/app_release.dart';
import '../services/update/update_installer.dart';
import '../services/update/update_preferences.dart';
import '../services/update/update_service.dart';

/// 更新状态机的阶段（设置页据此渲染状态与可用操作）。
enum UpdateStatus {
  /// 尚未检查（或切换渠道后结果作废）。
  idle,

  /// 正在拉取清单。
  checking,

  /// 已是最新。
  upToDate,

  /// 有可用更新，尚未下载。
  available,

  /// 正在下载安装包。
  downloading,

  /// 安装包已就绪（等待安装 / 等待授权）。
  downloaded,

  /// 已交给系统安装器或替换脚本。
  installing,

  /// 出错，[UpdateProvider.failure] 给出类别。
  error,
}

/// 下载进度。
///
/// 高频值不进 `notifyListeners`（仓库约定）：由
/// [UpdateProvider.progress] 这个 ValueListenable 单独承载。
class UpdateProgress {
  const UpdateProgress({
    this.received = 0,
    this.total = -1,
    this.bytesPerSecond = 0,
  });

  final int received;

  /// 总字节数；-1 表示服务器没给 Content-Length。
  final int total;

  final int bytesPerSecond;

  /// 0..1；未知总量时为 null（UI 显示不确定进度条）。
  double? get fraction =>
      total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

/// 设置页「关于与更新」的状态机：检查 → 下载 → 安装。
///
/// 职责边界：
/// - 平台差异（安装方式 / 架构）全部在 `UpdateService` 之下，这里只按
///   [UpdateStatus] 编排并暴露给 UI；
/// - 退出进程（桌面替换脚本就绪后）经注入的 [quitApp] 回调，provider 不
///   直接依赖窗口实现，测试可注入假实现。
class UpdateProvider extends ChangeNotifier {
  UpdateProvider({
    required UpdateService service,
    required UpdatePreferences preferences,
    required String currentVersion,
    required int currentBuild,
    Future<void> Function()? quitApp,
    DateTime Function()? now,
  })  : _service = service,
        _preferences = preferences,
        _currentVersion = currentVersion,
        _currentBuild = currentBuild,
        _quitApp = quitApp,
        _now = now ?? DateTime.now;

  /// 启动静默检查的节流间隔。
  static const Duration autoCheckInterval = Duration(hours: 24);

  static const Duration _progressThrottle = Duration(milliseconds: 100);

  final UpdateService _service;
  final UpdatePreferences _preferences;
  final String _currentVersion;
  final int _currentBuild;
  final Future<void> Function()? _quitApp;
  final DateTime Function() _now;
  final Logger _logger = Logger('molia.update_provider');

  /// 下载进度（高频通道）。
  final ValueNotifier<UpdateProgress> progress =
      ValueNotifier(const UpdateProgress());

  UpdateStatus _status = UpdateStatus.idle;
  AppRelease? _release;
  UpdateFailureKind? _failure;
  UpdatePlatformInfo? _platform;
  String? _downloadedPath;
  String? _downloadedKind;
  CancelToken? _cancelToken;
  DateTime? _lastProgressEmit;
  DateTime? _downloadStartedAt;

  UpdateStatus get status => _status;

  /// 清单里的最新发布（检查成功后有值）。
  AppRelease? get release => _release;

  UpdateFailureKind? get failure => _failure;

  DateTime? get lastCheckedAt => _preferences.lastCheckedAt;

  bool get autoCheckEnabled => _preferences.autoCheckEnabled;

  /// 当前平台是否支持切换测试渠道（Web 的 Pages 只部署稳定版清单）。
  ///
  /// 由运行时的平台信息判定（`_platform` 只有在 Web 构建里才会是 web），
  /// 不用编译期常量，便于测试注入平台。
  bool get channelSelectable => _platform?.platform != 'web';

  /// 生效渠道：Web 收敛为稳定版，原生端用用户选择。
  UpdateChannel get effectiveChannel =>
      channelSelectable ? _preferences.channel : UpdateChannel.stable;

  UpdateChannel get channel => _preferences.channel;

  String get manifestUrlOverride => _preferences.manifestUrlOverride;

  String get downloadPrefix => _preferences.downloadPrefix;

  UpdatePlatformInfo? get platform => _platform;

  /// 当前版本展示文案（当前版本 + 构建号）。
  String get currentVersionLabel =>
      '$_currentVersion+$_currentBuild';

  /// 是否处于「有更新可用」的任一阶段（设置入口副标题据此显示）。
  bool get updateAvailable =>
      _release != null &&
      (_status == UpdateStatus.available ||
          _status == UpdateStatus.downloading ||
          _status == UpdateStatus.downloaded);

  /// 当前平台是否支持应用内安装（Web 走刷新页面；iOS 走 App Store）。
  bool get supportsInAppInstall {
    final platform = _platform?.platform;
    return platform != null && platform != 'web' && platform != 'ios';
  }

  /// 是否已有下载好的安装包（授权后可直接重试安装）。
  bool get hasDownloadedPackage => _downloadedPath != null;

  Future<void> init() async {
    await _preferences.load();
    try {
      _platform = await _service.platformInfo();
    } catch (e) {
      _logger.warning('读取平台信息失败: $e');
    }
    notifyListeners();
  }

  /// 启动时的静默检查：已开启且距上次超过 [autoCheckInterval] 才发请求。
  Future<bool> maybeAutoCheck() async {
    if (!autoCheckEnabled) return false;
    final last = _preferences.lastCheckedAt;
    if (last != null && _now().difference(last) < autoCheckInterval) {
      return false;
    }
    await check(silent: true);
    return true;
  }

  /// 检查更新。[silent] 为 true 时不进入错误态（启动静默检查失败静默）。
  Future<void> check({bool silent = false}) async {
    if (_status == UpdateStatus.checking ||
        _status == UpdateStatus.downloading) {
      return;
    }
    _failure = null;
    _setStatus(UpdateStatus.checking);
    try {
      final result = await _service.check(
        channel: effectiveChannel,
        currentVersion: _currentVersion,
        currentBuild: _currentBuild,
      );
      _release = result.release;
      await _preferences.markChecked(_now());
      _setStatus(
        result.available ? UpdateStatus.available : UpdateStatus.upToDate,
      );
    } on UpdateFailureException catch (e) {
      _logger.info('检查更新失败: $e');
      if (silent) {
        _setStatus(UpdateStatus.idle);
      } else {
        _failure = e.kind;
        _setStatus(UpdateStatus.error);
      }
    } catch (e) {
      _logger.warning('检查更新异常: $e');
      if (silent) {
        _setStatus(UpdateStatus.idle);
      } else {
        _failure = UpdateFailureKind.network;
        _setStatus(UpdateStatus.error);
      }
    }
  }

  /// 下载并安装（Web 端退化为刷新页面）。
  Future<void> downloadAndInstall() async {
    if (!supportsInAppInstall) {
      await reloadPage();
      return;
    }
    if (_release == null || _platform == null) return;
    if (_status == UpdateStatus.downloading) return;

    _failure = null;
    _setStatus(UpdateStatus.downloading);
    _resetProgress();
    _downloadStartedAt = _now();
    _lastProgressEmit = null;
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    try {
      final path = await _service.download(
        release: _release!,
        platform: _platform!,
        onProgress: _onProgress,
        cancelToken: cancelToken,
      );
      _downloadedPath = path;
      _downloadedKind = _release!.assetFor(
        platform: _platform!.platform,
        arch: _platform!.arch,
      )?.kind;
      _setStatus(UpdateStatus.downloaded);
      await installDownloaded();
    } on UpdateFailureException catch (e) {
      _logger.warning('下载更新失败: $e');
      _failure = e.kind;
      _setStatus(UpdateStatus.error);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        _setStatus(UpdateStatus.available);
      } else {
        _failure = UpdateFailureKind.network;
        _setStatus(UpdateStatus.error);
      }
    } catch (e) {
      _logger.warning('下载更新异常: $e');
      _failure = UpdateFailureKind.network;
      _setStatus(UpdateStatus.error);
    } finally {
      _cancelToken = null;
    }
  }

  /// 安装已下载的包（用于授权后重试 / 手动触发）。
  Future<void> installDownloaded() async {
    final path = _downloadedPath;
    if (path == null) return;

    if (!await _service.canInstallPackages()) {
      _failure = UpdateFailureKind.permission;
      _setStatus(UpdateStatus.downloaded);
      return;
    }

    _setStatus(UpdateStatus.installing);
    try {
      final outcome = await _service.install(
        archivePath: path,
        archiveKind: _downloadedKind ?? 'zip',
      );
      switch (outcome) {
        case InstallOutcome.handedOff:
          // 系统安装器接管，应用继续运行。
          _failure = null;
          _setStatus(UpdateStatus.installing);
        case InstallOutcome.restartPending:
          // 桌面替换脚本已启动：退出进程后由脚本完成替换并重启。
          _failure = null;
          _setStatus(UpdateStatus.installing);
          await _quitApp?.call();
        case InstallOutcome.needPermission:
          _failure = UpdateFailureKind.permission;
          _setStatus(UpdateStatus.downloaded);
        case InstallOutcome.notWritable:
          _failure = UpdateFailureKind.notWritable;
          _setStatus(UpdateStatus.downloaded);
        case InstallOutcome.unsupported:
          _failure = UpdateFailureKind.unsupported;
          _setStatus(UpdateStatus.error);
        case InstallOutcome.failed:
          _failure = UpdateFailureKind.installFailed;
          _setStatus(UpdateStatus.error);
      }
    } on UpdateFailureException catch (e) {
      _logger.warning('安装更新失败: $e');
      _failure = e.kind;
      _setStatus(UpdateStatus.error);
    } catch (e) {
      _logger.warning('安装更新异常: $e');
      _failure = UpdateFailureKind.installFailed;
      _setStatus(UpdateStatus.error);
    }
  }

  /// 取消进行中的下载（已在下载的文件由下载器清掉）。
  void cancelDownload() {
    _cancelToken?.cancel('用户取消下载');
  }

  /// 打开「安装未知应用」授权页（Android）。
  Future<void> openInstallPermissionSettings() =>
      _service.openInstallPermissionSettings();

  /// Web 的「刷新以更新」。
  Future<void> reloadPage() => _service.reloadPage();

  Future<void> setAutoCheckEnabled(bool value) async {
    if (_preferences.autoCheckEnabled == value) return;
    await _preferences.setAutoCheckEnabled(value);
    notifyListeners();
  }

  Future<void> setChannel(UpdateChannel value) async {
    if (_preferences.channel == value) return;
    await _preferences.setChannel(value);
    // 渠道切换后旧结果作废（新渠道可能没有更新或版本更旧）。
    _release = null;
    _failure = null;
    _setStatus(UpdateStatus.idle);
    notifyListeners();
  }

  Future<void> setManifestUrlOverride(String value) async {
    if (_preferences.manifestUrlOverride == value.trim()) return;
    await _preferences.setManifestUrlOverride(value);
    notifyListeners();
  }

  Future<void> setDownloadPrefix(String value) async {
    if (_preferences.downloadPrefix == value.trim()) return;
    await _preferences.setDownloadPrefix(value);
    notifyListeners();
  }

  void _onProgress(int received, int total) {
    final now = _now();
    final emit = _lastProgressEmit == null ||
        now.difference(_lastProgressEmit!) >= _progressThrottle ||
        (total > 0 && received >= total);
    if (!emit) return;
    _lastProgressEmit = now;

    final started = _downloadStartedAt;
    final elapsedMs =
        started == null ? 0 : now.difference(started).inMilliseconds;
    progress.value = UpdateProgress(
      received: received,
      total: total,
      bytesPerSecond: elapsedMs > 0 ? (received * 1000 / elapsedMs).round() : 0,
    );
  }

  void _resetProgress() => progress.value = const UpdateProgress();

  void _setStatus(UpdateStatus status) {
    if (_status == status) {
      notifyListeners();
      return;
    }
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelToken?.cancel('provider disposed');
    progress.dispose();
    super.dispose();
  }
}
