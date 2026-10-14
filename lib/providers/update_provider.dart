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

  /// 已下载安装包对应的发布：检查结果换版本后必须作废，避免把旧包当新包安装。
  AppRelease? _downloadedRelease;
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

  /// 是否已有「与当前清单一致」的下载包（授权后可直接重试安装）。
  bool get hasDownloadedPackage =>
      _downloadedPath != null && _sameAsDownloaded(_release);

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
    final previousFailure = _failure;
    _failure = null;
    _setStatus(UpdateStatus.checking);
    try {
      final result = await _service.check(
        channel: effectiveChannel,
        currentVersion: _currentVersion,
        currentBuild: _currentBuild,
      );
      // 已下载的安装包只在「还是同一发布」时保留：换版本后旧包作废，
      // 否则会把上一次下载的版本当成当前可安装版本展示/安装。
      final sameAsDownloaded = _sameAsDownloaded(result.release);
      if (_downloadedPath != null && !sameAsDownloaded) {
        _clearDownloaded();
      }
      _release = result.release;
      await _preferences.markChecked(_now());
      if (!result.available) {
        _failure = null;
        _setStatus(UpdateStatus.upToDate);
      } else if (sameAsDownloaded) {
        // 同一发布的包已就绪：保留 downloaded 态（含「待授权」失败态），
        // 不因一次检查回退成「下载并安装」。
        _failure = previousFailure == UpdateFailureKind.permission
            ? previousFailure
            : null;
        _setStatus(UpdateStatus.downloaded);
      } else {
        _failure = null;
        _setStatus(UpdateStatus.available);
      }
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

    // 先确认安装权限再下载：Android 没有「安装未知应用」权限时，下完再被
    // 系统安装器拦下会白等十几 MB。
    if (!await _service.canInstallPackages()) {
      _failure = UpdateFailureKind.permission;
      _setStatus(
        _downloadedPath != null
            ? UpdateStatus.downloaded
            : UpdateStatus.available,
      );
      return;
    }

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
      _downloadedRelease = _release;
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

  /// App 回到前台时的更新态复查（组合根在 onResume 调用）。
  ///
  /// - 系统安装器被用户取消：状态停在 installing 但没有真的安装 → 回到
  ///   「安装包已就绪」，允许重试；
  /// - 从「安装未知应用」授权页返回：复查权限，把「去授权」切回可安装/可下载态。
  Future<void> handleAppResumed() async {
    if (_status == UpdateStatus.installing && _downloadedPath != null) {
      _setStatus(UpdateStatus.downloaded);
    }
    if (_failure != UpdateFailureKind.permission) return;
    if (!await _service.canInstallPackages()) return;
    _failure = null;
    if (_release == null) {
      _setStatus(UpdateStatus.idle);
    } else {
      _setStatus(
        _downloadedPath != null
            ? UpdateStatus.downloaded
            : UpdateStatus.available,
      );
    }
  }

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
    // 渠道切换后旧结果与旧安装包都作废（新渠道可能没有更新或版本更旧）。
    _release = null;
    _failure = null;
    _clearDownloaded();
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

  /// 清单里的发布是否与已下载安装包同源（版本 + 构建号一致）。
  bool _sameAsDownloaded(AppRelease? release) {
    final downloaded = _downloadedRelease;
    if (release == null || downloaded == null) return false;
    return downloaded.version == release.version &&
        downloaded.build == release.build;
  }

  /// 作废已下载的安装包状态（文件留待下次下载时统一清理）。
  void _clearDownloaded() {
    _downloadedPath = null;
    _downloadedKind = null;
    _downloadedRelease = null;
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
