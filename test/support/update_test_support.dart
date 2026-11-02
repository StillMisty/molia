/// 应用内更新的测试支撑：服务 / 偏好替身（provider 与页面测试共用）。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:molia/domain/models/app_release.dart';
import 'package:molia/services/update/update_installer_types.dart';
import 'package:molia/services/update/update_preferences.dart';
import 'package:molia/services/update/update_service.dart';

/// 更新编排的服务替身：所有外部效果都可编排。
class FakeUpdateService implements UpdateService {
  UpdatePlatformInfo platform = const UpdatePlatformInfo(
    platform: 'linux',
    arch: 'x64',
  );
  AppRelease? manifest;
  Object? checkError;
  Object? downloadError;
  Object? installError;
  InstallOutcome installOutcome = InstallOutcome.handedOff;
  bool installPermission = true;
  String downloadPath = '/tmp/updates/molia-1.2.3-linux-x64.tar.gz';

  /// 指定 download 返回的产物（模拟服务已按安装形态选好）；null 时按
  /// `assetFor` 回退，与真实服务的「找不到偏好类别」分支一致。
  ReleaseAsset? downloadAsset;
  UpdateChannel? lastCheckChannel;
  int downloadCalls = 0;

  /// install 实际收到的产物类别（验证调用方用的是下载结果而不是二次猜）。
  String? lastInstallKind;

  /// 非空时 check 会等待该 Completer（测试「检查中」界面态用）。
  Completer<void>? checkGate;

  /// 非空时 download 会等待该 Completer（测试「下载中改配置」界面态用）。
  Completer<void>? downloadGate;

  /// 每次 onProgress 前调用（测试推进可控时钟，验证速度计算）。
  void Function(int received, int total)? onProgressHook;
  int openPermissionCalls = 0;
  int installCalls = 0;

  /// 构造一个「比 1.2.2+41 新」的发布（默认清单）。
  AppRelease release(String version, int build) => AppRelease(
    channel: UpdateChannel.stable,
    version: version,
    build: build,
    // 真实清单带 notesUrl（发布页）：页面据此把「打开下载页」收进
    // 主操作的尾部菜单。
    notesUrl: Uri.parse('https://example.com/releases/tag/v$version'),
    assets: [
      ReleaseAsset(
        platform: 'linux',
        arch: 'x64',
        kind: 'tar.gz',
        url: Uri.parse('https://example.com/molia.tar.gz'),
        file: 'molia-$version-linux-x64.tar.gz',
        size: 12 * 1024 * 1024,
        sha256: 'abc',
      ),
    ],
  );

  @override
  Future<UpdatePlatformInfo> platformInfo() async => platform;

  @override
  Future<ReleaseAsset?> selectAsset({
    required AppRelease release,
    required UpdatePlatformInfo platform,
  }) async =>
      downloadAsset ??
      release.assetFor(platform: platform.platform, arch: platform.arch);

  @override
  Future<UpdateCheckResult> check({
    required UpdateChannel channel,
    required String currentVersion,
    required int currentBuild,
  }) async {
    final error = checkError;
    if (error != null) throw error;
    final gate = checkGate;
    if (gate != null) await gate.future;
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
  Future<DownloadedUpdate> download({
    required AppRelease release,
    required UpdatePlatformInfo platform,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    final error = downloadError;
    if (error != null) throw error;
    final gate = downloadGate;
    if (gate != null) await gate.future;
    // 替身不实现真实的产物选择：默认清单只有 linux 产物，Android 等
    // provider 用例只关心流程，找不到匹配时退回第一个产物即可。
    final asset =
        downloadAsset ??
        release.assetFor(platform: platform.platform, arch: platform.arch) ??
        (release.assets.isEmpty ? null : release.assets.first);
    if (asset == null) {
      throw const UpdateFailureException(
        UpdateFailureKind.unsupported,
        '清单没有适配产物',
      );
    }
    downloadCalls++;
    onProgressHook?.call(5, 10);
    onProgress(5, 10);
    onProgressHook?.call(10, 10);
    onProgress(10, 10);
    return DownloadedUpdate(path: downloadPath, asset: asset);
  }

  @override
  Future<InstallOutcome> install({
    required String archivePath,
    required String archiveKind,
  }) async {
    installCalls++;
    lastInstallKind = archiveKind;
    final error = installError;
    if (error != null) throw error;
    return installOutcome;
  }

  @override
  Future<bool> canInstallPackages() async => installPermission;

  @override
  Future<void> openInstallPermissionSettings() async {
    openPermissionCalls++;
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
  PendingUpdate? pendingUpdate;

  /// pending 写入 / 清除次数（provider 生命周期断言用）。
  int markPendingCalls = 0;
  int clearPendingCalls = 0;

  /// check 写「上次检查时间」时的闸门（测试写偏好期间的代际竞态）。
  Completer<void>? markCheckedStarted;
  Completer<void>? markCheckedGate;

  @override
  Future<void> load() async {}

  @override
  Future<void> markChecked(DateTime at) async {
    markCheckedStarted?.complete();
    final gate = markCheckedGate;
    if (gate != null) await gate.future;
    lastCheckedAt = at;
  }

  @override
  Future<void> markPendingUpdate({
    required String version,
    required int build,
  }) async {
    markPendingCalls++;
    pendingUpdate = PendingUpdate(version: version, build: build);
  }

  @override
  Future<void> clearPendingUpdate() async {
    clearPendingCalls++;
    pendingUpdate = null;
  }

  @override
  Future<void> setAutoCheckEnabled(bool value) async =>
      autoCheckEnabled = value;

  @override
  Future<void> setChannel(UpdateChannel value) async => channel = value;

  @override
  Future<void> setDownloadPrefix(String value) async => downloadPrefix = value;

  @override
  Future<void> setManifestUrlOverride(String value) async =>
      manifestUrlOverride = value;
}
