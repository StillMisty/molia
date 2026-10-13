/// 应用内更新的测试支撑：服务 / 偏好替身（provider 与页面测试共用）。
library;

import 'package:dio/dio.dart';
import 'package:molia/domain/models/app_release.dart';
import 'package:molia/services/update/update_installer_types.dart';
import 'package:molia/services/update/update_preferences.dart';
import 'package:molia/services/update/update_service.dart';

/// 更新编排的服务替身：所有外部效果都可编排。
class FakeUpdateService implements UpdateService {
  UpdatePlatformInfo platform =
      const UpdatePlatformInfo(platform: 'linux', arch: 'x64');
  AppRelease? manifest;
  Object? checkError;
  Object? downloadError;
  InstallOutcome installOutcome = InstallOutcome.handedOff;
  bool installPermission = true;
  String downloadPath = '/tmp/updates/molia-1.2.3-linux-x64.tar.gz';
  UpdateChannel? lastCheckChannel;
  int reloadCalls = 0;
  int openPermissionCalls = 0;
  int installCalls = 0;

  /// 构造一个「比 1.2.2+41 新」的发布（默认清单）。
  AppRelease release(String version, int build) => AppRelease(
        channel: UpdateChannel.stable,
        version: version,
        build: build,
        assets: [
          ReleaseAsset(
            platform: 'linux',
            arch: 'x64',
            kind: 'tar.gz',
            url: Uri.parse('https://example.com/molia.tar.gz'),
            file: 'molia-$version-linux-x64.tar.gz',
            sha256: 'abc',
          ),
        ],
      );

  @override
  Future<UpdatePlatformInfo> platformInfo() async => platform;

  @override
  Future<UpdateCheckResult> check({
    required UpdateChannel channel,
    required String currentVersion,
    required int currentBuild,
  }) async {
    final error = checkError;
    if (error != null) throw error;
    lastCheckChannel = channel;
    final latest = manifest ?? release('1.2.3', 42);
    return UpdateCheckResult(
      release: latest,
      available: latest.isNewerThan(
        currentVersion: currentVersion,
        currentBuild: currentBuild,
      ),
    );
  }

  @override
  Future<String> download({
    required AppRelease release,
    required UpdatePlatformInfo platform,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    final error = downloadError;
    if (error != null) throw error;
    onProgress(5, 10);
    onProgress(10, 10);
    return downloadPath;
  }

  @override
  Future<InstallOutcome> install({
    required String archivePath,
    required String archiveKind,
  }) async {
    installCalls++;
    return installOutcome;
  }

  @override
  Future<bool> canInstallPackages() async => installPermission;

  @override
  Future<void> openInstallPermissionSettings() async {
    openPermissionCalls++;
  }

  @override
  Future<void> reloadPage() async {
    reloadCalls++;
  }
}

/// 更新偏好的内存替身。
class FakeUpdatePreferences implements UpdatePreferences {
  @override
  bool autoCheckEnabled = false;
  @override
  UpdateChannel channel = UpdateChannel.stable;
  @override
  String manifestUrlOverride = '';
  @override
  String downloadPrefix = '';
  @override
  DateTime? lastCheckedAt;

  @override
  Future<void> load() async {}

  @override
  Future<void> markChecked(DateTime at) async => lastCheckedAt = at;

  @override
  Future<void> setAutoCheckEnabled(bool value) async => autoCheckEnabled = value;

  @override
  Future<void> setChannel(UpdateChannel value) async => channel = value;

  @override
  Future<void> setDownloadPrefix(String value) async => downloadPrefix = value;

  @override
  Future<void> setManifestUrlOverride(String value) async =>
      manifestUrlOverride = value;
}
