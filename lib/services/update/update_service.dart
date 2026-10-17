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

/// 更新编排：检查（取清单 + 比版本）→ 下载（挑产物 + 校验）→ 安装（平台策略）。
///
/// 只做流程编排，不带状态：状态机在 `providers/update_provider.dart`，
/// UI 不直接持有本服务。
class UpdateService {
  UpdateService({
    required UpdateManifestClient client,
    required UpdateDownloader downloader,
    required UpdateInstaller installer,
  })  : _client = client,
        _downloader = downloader,
        _installer = installer;

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

  /// 下载当前平台适配的产物，返回本地文件路径。
  ///
  /// 产物类别按本机安装形态选择（Windows 安装版取 `setup.exe`，便携版取 zip），
  /// 找不到对应类别时回退到该平台的任意产物。
  Future<String> download({
    required AppRelease release,
    required UpdatePlatformInfo platform,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    final preferredKind = await _installer.preferredArchiveKind();
    final asset = (preferredKind == null
            ? null
            : release.assetOfKind(
                platform: platform.platform,
                arch: platform.arch,
                kind: preferredKind,
              )) ??
        release.assetFor(platform: platform.platform, arch: platform.arch);
    if (asset == null) {
      throw UpdateFailureException(
        UpdateFailureKind.unsupported,
        '清单没有适配 ${platform.platform}/${platform.arch} 的产物',
      );
    }
    return _downloader.download(
      url: _client.resolveAssetUri(asset.url),
      targetFileName: asset.file ?? 'molia-${release.version}.${asset.kind}',
      sha256: asset.sha256,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// 安装已下载的产物（Android 交给系统安装器；桌面启动替换脚本）。
  Future<InstallOutcome> install({
    required String archivePath,
    required String archiveKind,
  }) =>
      _installer.installAndRestart(
        archivePath: archivePath,
        archiveKind: archiveKind,
      );

  Future<bool> canInstallPackages() => _installer.canInstallPackages();

  Future<void> openInstallPermissionSettings() =>
      _installer.openInstallPermissionSettings();
}
