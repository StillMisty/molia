import 'package:dio/dio.dart';

import '../../data/update/update_downloader.dart';
import '../../data/update/update_manifest_client.dart';
import '../../domain/models/app_release.dart';
import 'update_installer.dart';

/// 一次更新检查的结果。
class UpdateCheckResult {
  const UpdateCheckResult({required this.release, required this.available});

  /// 清单里的最新发布。
  final AppRelease release;

  /// 是否比当前安装的版本新。
  final bool available;
}

/// 一次下载的结果：本地文件路径 + 实际选中的清单产物。
///
/// 为什么把产物一起返回：产物类别由本服务按本机安装形态选择，调用方若再
/// 按清单顺序反推（`assetFor`）会挑到另一种分发形态（Windows 清单里
/// `-setup.exe` 常排在 `.zip` 前，安装策略会拿 zip 当 exe），安装必须
/// 使用与下载完全相同的那一份选择结果。
class DownloadedUpdate {
  const DownloadedUpdate({required this.path, required this.asset});

  /// 下载到本地的文件路径。
  final String path;

  /// 实际下载的产物（[ReleaseAsset.kind] 供安装策略选择安装方式）。
  final ReleaseAsset asset;
}

/// 更新编排：检查（取清单 + 比版本）→ 下载（挑产物 + 校验）→ 安装（平台策略）。
///
/// 只做流程编排，不带状态：状态机在 `providers/update_provider.dart`，
/// UI 不直接持有本服务。
class UpdateService {
  UpdateService({
    required this._client,
    required this._downloader,
    required this._installer,
  });

  final UpdateManifestClient _client;
  final UpdateDownloader _downloader;
  final UpdateInstaller _installer;

  Future<UpdatePlatformInfo> platformInfo() => _installer.platformInfo();

  /// 拉取指定渠道的清单并与当前版本比较。
  Future<UpdateCheckResult> check({
    required UpdateChannel channel,
    required String currentVersion,
    required int currentBuild,
  }) async {
    final release = await _client.fetch(channel);
    return UpdateCheckResult(
      release: release,
      available: release.isNewerThan(
        currentVersion: currentVersion,
        currentBuild: currentBuild,
      ),
    );
  }

  /// 选出当前平台实际要下载的产物（不触发下载）。
  ///
  /// 产物类别按本机安装形态选择（Windows 安装版取 `setup.exe`，便携版取
  /// zip），找不到对应类别时回退到该平台的任意产物。发布卡片的安装包大小
  /// 与真正下载必须用同一种选择，避免显示 setup 大小却下载 zip。
  Future<ReleaseAsset?> selectAsset({
    required AppRelease release,
    required UpdatePlatformInfo platform,
  }) async {
    final preferredKind = await _installer.preferredArchiveKind();
    return (preferredKind == null
            ? null
            : release.assetOfKind(
                platform: platform.platform,
                arch: platform.arch,
                kind: preferredKind,
              )) ??
        release.assetFor(platform: platform.platform, arch: platform.arch);
  }

  /// 下载当前平台适配的产物，返回路径与实际产物。
  Future<DownloadedUpdate> download({
    required AppRelease release,
    required UpdatePlatformInfo platform,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    final asset = await selectAsset(release: release, platform: platform);
    if (asset == null) {
      throw UpdateFailureException(
        UpdateFailureKind.unsupported,
        '清单没有适配 ${platform.platform}/${platform.arch} 的产物',
      );
    }
    final path = await _downloader.download(
      url: _client.resolveAssetUri(asset.url),
      targetFileName: asset.file ?? 'molia-${release.version}.${asset.kind}',
      sha256: asset.sha256,
      expectedSize: asset.size,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    return DownloadedUpdate(path: path, asset: asset);
  }

  /// 安装已下载的产物（Android 交给系统安装器；桌面启动替换脚本）。
  Future<InstallOutcome> install({
    required String archivePath,
    required String archiveKind,
  }) => _installer.installAndRestart(
    archivePath: archivePath,
    archiveKind: archiveKind,
  );

  Future<bool> canInstallPackages() => _installer.canInstallPackages();

  Future<void> openInstallPermissionSettings() =>
      _installer.openInstallPermissionSettings();
}
