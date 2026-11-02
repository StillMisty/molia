import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../domain/models/app_release.dart';
import '../services/update/update_installer.dart';
import '../services/update/update_notification_presenter.dart';
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

/// 上次交给安装器后的结果回执（下次启动对比版本得出）。
enum UpdateInstallResult {
  /// 当前版本已达到目标：安装成功。
  succeeded,

  /// 仍低于目标：安装没有完成。
  incomplete,
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
  double? get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

/// 设置页「关于与更新」的状态机：检查 → 下载 → 安装。
///
/// 职责边界：
/// - 平台差异（安装方式 / 架构）全部在 `UpdateService` 之下，这里只按
///   [UpdateStatus] 编排并暴露给 UI；
/// - 退出进程（桌面替换脚本就绪后）经注入的 [quitApp] 回调，provider 不
///   直接依赖窗口实现，测试可注入假实现；
/// - 下载通知经 [UpdateNotificationPresenter] 管理（端口 / 节流在里面），
///   这里只报「开始 / 进度 / 收尾」，不感知 Android 通道细节。
class UpdateProvider extends ChangeNotifier {
  UpdateProvider({
    required this._service,
    required this._preferences,
    this._notificationPresenter,
    this._ensureNotificationPermission,
    this._currentVersion = '0.0.0',
    this._currentBuild = 0,
    this._quitApp,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 启动静默检查的节流间隔。
  static const Duration autoCheckInterval = Duration(hours: 24);

  static const Duration _progressThrottle = Duration(milliseconds: 100);

  final UpdateService _service;
  final UpdatePreferences _preferences;
  final UpdateNotificationPresenter? _notificationPresenter;

  /// Android 下载前请求通知权限（仅通知用途，拒绝 / 失败不阻断下载）。
  final Future<void> Function()? _ensureNotificationPermission;

  /// 由 [start] 从平台包信息填入（构造时是占位值）。
  String _currentVersion;
  int _currentBuild;
  final Future<void> Function()? _quitApp;
  final DateTime Function() _now;
  final Logger _logger = Logger('molia.update_provider');

  /// 下载进度（高频通道）。
  final ValueNotifier<UpdateProgress> progress = ValueNotifier(
    const UpdateProgress(),
  );

  UpdateStatus _status = UpdateStatus.idle;
  AppRelease? _release;

  /// 与 [release] 对应的实际下载产物（发布卡片的安装包大小用）。
  ReleaseAsset? _selectedAsset;
  UpdateFailureKind? _failure;
  UpdateInstallResult? _installResult;
  String? _installResultVersion;
  UpdatePlatformInfo? _platform;
  String? _downloadedPath;
  String? _downloadedKind;

  /// 已下载安装包对应的发布：检查结果换版本后必须作废，避免把旧包当新包安装。
  AppRelease? _downloadedRelease;
  CancelToken? _cancelToken;
  DateTime? _lastProgressEmit;
  DateTime? _downloadStartedAt;

  /// 本次下载首个进度回调的 received：续传时它已含上次 part 的字节，
  /// 速度只能按「之后新增的字节」计算，否则会出现几十 MB/s 的假峰值。
  int? _progressBase;

  /// 检查代际：切换渠道 / 改清单地址 / 改镜像前缀时递增，旧请求返回后
  /// 据此丢弃结果，避免旧渠道 / 旧配置的回填覆盖新状态。
  int _checkGeneration = 0;

  UpdateStatus get status => _status;

  /// 清单里的最新发布（检查成功后有值）。
  AppRelease? get release => _release;

  /// 当前发布实际会下载的产物（大小展示与下载共用同一次选择）。
  ReleaseAsset? get releaseAsset => _selectedAsset;

  /// 上次安装结果回执；null 表示没有待展示的回执。
  UpdateInstallResult? get installResult => _installResult;

  /// 回执对应的目标版本。
  String? get installResultVersion => _installResultVersion;

  UpdateFailureKind? get failure => _failure;

  DateTime? get lastCheckedAt => _preferences.lastCheckedAt;

  bool get autoCheckEnabled => _preferences.autoCheckEnabled;

  UpdateChannel get channel => _preferences.channel;

  String get manifestUrlOverride => _preferences.manifestUrlOverride;

  String get downloadPrefix => _preferences.downloadPrefix;

  UpdatePlatformInfo? get platform => _platform;

  /// 当前版本展示文案（当前版本 + 构建号）。
  String get currentVersionLabel => '$_currentVersion+$_currentBuild';

  /// 是否处于「有更新可用」的任一阶段（设置入口副标题据此显示）。
  bool get updateAvailable =>
      _release != null &&
      (_status == UpdateStatus.available ||
          _status == UpdateStatus.downloading ||
          _status == UpdateStatus.downloaded);

  /// 当前平台是否支持应用内安装。
  ///
  /// 用白名单而不是「排除 iOS」：macOS 虽能下载，但安装策略没有 macOS 分支
  /// （只会返回 unsupported），未知平台也不应默认落进不可用的安装路径。
  bool get supportsInAppInstall {
    final platform = _platform?.platform;
    return platform == 'android' ||
        platform == 'windows' ||
        platform == 'linux';
  }

  /// 是否已有「与当前清单一致」的下载包（授权后可直接重试安装）。
  bool get hasDownloadedPackage =>
      _downloadedPath != null && _sameAsDownloaded(_release);

  /// 启动准备（组合根在**首帧之后**调用一次）：平台包信息 → 本地偏好 →
  /// 平台信息。
  ///
  /// 为什么后移：读包信息要过平台通道，读偏好要碰磁盘，两者都不参与首帧
  /// 内容，放在 `runApp` 之前只是让用户多等一次 IPC（桌面实测 ~14ms）。
  /// 后移不改变可见行为——自动检查（[maybeAutoCheck]）本来就排在首帧之后，
  /// 且排在 [start] 之后（见 `post_frame_init.dart`）。
  Future<void> start() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      _currentVersion = packageInfo.version;
      _currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
    } catch (e) {
      debugPrint('[Molia] 读取应用版本失败（更新检查按 0.0.0 处理）: $e');
    }
    await init();
  }

  Future<void> init() async {
    await _preferences.load();
    await _consumePendingInstallResult();
    try {
      _platform = await _service.platformInfo();
    } catch (e) {
      _logger.warning('读取平台信息失败: $e');
    }
    notifyListeners();
  }

  /// 启动时消费上次安装留下的 pending：版本达到即成功，否则判为未完成。
  Future<void> _consumePendingInstallResult() async {
    final pending = _preferences.pendingUpdate;
    if (pending == null) return;
    _installResult =
        pending.isSatisfiedBy(version: _currentVersion, build: _currentBuild)
        ? UpdateInstallResult.succeeded
        : UpdateInstallResult.incomplete;
    _installResultVersion = pending.version;
    await _preferences.clearPendingUpdate();
  }

  /// 启动时的静默检查：已开启且距上次超过 [autoCheckInterval] 才发请求。
  ///
  /// 只在启动后由组合根调用一次（见 `post_frame_init.dart`）：不做常驻轮询，
  /// 也不在回前台时触发；[autoCheckInterval] 只决定这次冷启动是否跳过。
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
        _status == UpdateStatus.downloading ||
        _status == UpdateStatus.installing) {
      return;
    }
    // 用户主动检查说明已经看到/处理回执：让旧结果提示不要黏住；启动静默
    // 检查不清，否则刚启动就把 pending 回执吞掉了。
    if (!silent) _clearInstallResult();
    final generation = _checkGeneration;
    final previousFailure = _failure;
    _failure = null;
    _setStatus(UpdateStatus.checking);
    try {
      final result = await _service.check(
        channel: _preferences.channel,
        currentVersion: _currentVersion,
        currentBuild: _currentBuild,
      );
      // 期间切了渠道 / 改了配置：旧请求的结果作废，不能写回状态或时间。
      if (generation != _checkGeneration) return;
      // 产物选择依赖本机安装形态（读 unins000.exe 等），失败只影响大小
      // 展示，不应让整次检查进入错误态。先算完再写状态，避免 selectAsset
      // 期间参数再次变化时留下半套旧结果。
      final selectedAsset = await _selectAsset(result.release);
      if (generation != _checkGeneration) return;
      // 已下载的安装包只在「还是同一发布」时保留：换版本后旧包作废，
      // 否则会把上一次下载的版本当成当前可安装版本展示/安装。
      final sameAsDownloaded = _sameAsDownloaded(result.release);
      if (_downloadedPath != null && !sameAsDownloaded) {
        _clearDownloaded();
      }
      _release = result.release;
      _selectedAsset = selectedAsset;
      await _preferences.markChecked(_now());
      // 写偏好本身也是 await：期间改渠道 / 配置仍要丢弃这次结果。
      if (generation != _checkGeneration) return;
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
      if (generation != _checkGeneration) return;
      _logger.info('检查更新失败: $e');
      if (silent) {
        _setStatus(UpdateStatus.idle);
      } else {
        _failure = e.kind;
        _setStatus(UpdateStatus.error);
      }
    } catch (e) {
      if (generation != _checkGeneration) return;
      _logger.warning('检查更新异常: $e');
      if (silent) {
        _setStatus(UpdateStatus.idle);
      } else {
        _failure = UpdateFailureKind.network;
        _setStatus(UpdateStatus.error);
      }
    }
  }

  /// 下载并安装。
  Future<void> downloadAndInstall() async {
    _clearInstallResult();
    if (!supportsInAppInstall) return;
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

    // Android 更新下载复用 dataSync 前台服务：先 best-effort 请求通知权限。
    // 拒绝 / 通道异常只损失进度通知，不能阻断下载。
    if (_platform?.platform == 'android') {
      try {
        await _ensureNotificationPermission?.call();
      } catch (e) {
        _logger.info('请求通知权限失败（继续下载）: $e');
      }
    }

    _failure = null;
    _setStatus(UpdateStatus.downloading);
    _resetProgress();
    _downloadStartedAt = _now();
    _lastProgressEmit = null;
    _progressBase = null;
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    try {
      _notificationPresenter?.start(version: _release!.version);
      final downloaded = await _service.download(
        release: _release!,
        platform: _platform!,
        onProgress: _onProgress,
        cancelToken: cancelToken,
      );
      // 下载完成立刻收通知：后续安装可能交给系统安装器或退出进程，不能等
      // finally，否则安装期间还会显示「正在下载」。
      _notificationPresenter?.stop();
      _downloadedPath = downloaded.path;
      // 用服务实际选中的产物类别，而不是按清单顺序反推：Windows 便携版
      // 清单里 `-setup.exe` 常排在 zip 前，反推会把 zip 当安装器。
      _selectedAsset = downloaded.asset;
      _downloadedKind = downloaded.asset.kind;
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
      // 失败 / 取消的兜底收尾。成功路径已在下载完成时提前 stop，这里依赖
      // presenter 的幂等实现变成 no-op，不会重复发通知。
      _notificationPresenter?.stop();
      _cancelToken = null;
    }
  }

  /// 安装已下载的包（用于授权后重试 / 手动触发）。
  Future<void> installDownloaded() async {
    _clearInstallResult();
    final path = _downloadedPath;
    if (path == null) return;

    if (!await _service.canInstallPackages()) {
      _failure = UpdateFailureKind.permission;
      _setStatus(UpdateStatus.downloaded);
      return;
    }

    // 交给安装器 / 替换脚本前先落盘目标版本：进程随后退出，下次启动只能
    // 靠它判断到底装没装成。写入失败只丢回执，不阻断安装。
    final targetRelease = _downloadedRelease ?? _release;
    if (targetRelease != null) {
      try {
        await _preferences.markPendingUpdate(
          version: targetRelease.version,
          build: targetRelease.build,
        );
      } catch (e) {
        _logger.warning('记录待确认更新失败（继续安装）: $e');
      }
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
          await _preferences.clearPendingUpdate();
          _failure = UpdateFailureKind.permission;
          _setStatus(UpdateStatus.downloaded);
        case InstallOutcome.notWritable:
          await _preferences.clearPendingUpdate();
          _failure = UpdateFailureKind.notWritable;
          _setStatus(UpdateStatus.downloaded);
        case InstallOutcome.unsupported:
          await _preferences.clearPendingUpdate();
          _failure = UpdateFailureKind.unsupported;
          _setStatus(UpdateStatus.error);
        case InstallOutcome.failed:
          await _preferences.clearPendingUpdate();
          _failure = UpdateFailureKind.installFailed;
          _setStatus(UpdateStatus.error);
      }
    } on UpdateFailureException catch (e) {
      await _preferences.clearPendingUpdate();
      _logger.warning('安装更新失败: $e');
      _failure = e.kind;
      _setStatus(UpdateStatus.error);
    } catch (e) {
      await _preferences.clearPendingUpdate();
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
      // 系统安装器被用户取消后回到应用：这次安装没有真正交接成功，不能
      // 留到下次启动误报「上次更新未完成」。
      await _preferences.clearPendingUpdate();
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

  Future<void> setAutoCheckEnabled(bool value) async {
    if (_preferences.autoCheckEnabled == value) return;
    await _preferences.setAutoCheckEnabled(value);
    notifyListeners();
  }

  Future<void> setChannel(UpdateChannel value) async {
    if (_preferences.channel == value) return;
    await _preferences.setChannel(value);
    // 渠道切换后旧结果与旧安装包都作废（新渠道可能没有更新或版本更旧）。
    _invalidateReleaseForChangedParameters();
  }

  Future<void> setManifestUrlOverride(String value) async {
    if (_preferences.manifestUrlOverride == value.trim()) return;
    await _preferences.setManifestUrlOverride(value);
    _invalidateReleaseForChangedParameters();
  }

  Future<void> setDownloadPrefix(String value) async {
    if (_preferences.downloadPrefix == value.trim()) return;
    await _preferences.setDownloadPrefix(value);
    _invalidateReleaseForChangedParameters();
  }

  /// 渠道 / 清单地址 / 镜像前缀改变后旧结果不再可信：清发布、产物与已
  /// 下载包，回到 idle；正在下载 / 安装时不能清，否则回调拿不到 release，
  /// 此时只保存配置，下一次检查自然使用新配置。
  void _invalidateReleaseForChangedParameters() {
    if (_status == UpdateStatus.downloading ||
        _status == UpdateStatus.installing) {
      notifyListeners();
      return;
    }
    _invalidateRelease();
    _setStatus(UpdateStatus.idle);
  }

  Future<ReleaseAsset?> _selectAsset(AppRelease release) async {
    final platform = _platform;
    if (platform == null) return null;
    try {
      return await _service.selectAsset(release: release, platform: platform);
    } catch (e) {
      // 只影响发布卡片的「安装包大小」行，检查结果本身仍然可用。
      _logger.info('选择更新产物失败: $e');
      return null;
    }
  }

  /// 清单里的发布是否与已下载安装包同源（版本 + 构建号一致）。
  bool _sameAsDownloaded(AppRelease? release) {
    final downloaded = _downloadedRelease;
    if (release == null || downloaded == null) return false;
    return downloaded.version == release.version &&
        downloaded.build == release.build;
  }

  /// 作废当前发布结果（发布、选中的产物、失败类别、回执与已下载包）。
  ///
  /// 同时递增检查代际：正在飞的 check 返回后必须丢弃，否则旧渠道 / 旧
  /// 配置的结果会在状态已清空后又写回来。
  void _invalidateRelease() {
    _checkGeneration++;
    _release = null;
    _selectedAsset = null;
    _failure = null;
    _clearInstallResult();
    _clearDownloaded();
  }

  void _clearInstallResult() {
    _installResult = null;
    _installResultVersion = null;
  }

  /// 作废已下载的安装包状态（文件留待下次下载时统一清理）。
  void _clearDownloaded() {
    _downloadedPath = null;
    _downloadedKind = null;
    _downloadedRelease = null;
  }

  void _onProgress(int received, int total) {
    final now = _now();
    final emit =
        _lastProgressEmit == null ||
        now.difference(_lastProgressEmit!) >= _progressThrottle ||
        (total > 0 && received >= total);
    if (!emit) return;
    _lastProgressEmit = now;
    _notificationPresenter?.updateProgress(received, total);

    // 续传时首个回调的 received 含上次 part 字节：把它作为基准，只按
    // 本次新增字节算速度；新下载同样从首片开始算增量，不写死为 0。
    final base = _progressBase ??= received;
    final started = _downloadStartedAt;
    final elapsedMs = started == null
        ? 0
        : now.difference(started).inMilliseconds;
    progress.value = UpdateProgress(
      received: received,
      total: total,
      bytesPerSecond: elapsedMs > 0
          ? ((received - base) * 1000 / elapsedMs).round()
          : 0,
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
    _notificationPresenter?.stop();
    progress.dispose();
    super.dispose();
  }
}
