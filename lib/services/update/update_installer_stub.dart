import 'dart:js_interop';

import 'update_installer_types.dart';

/// Web 平台的更新策略：浏览器沙箱不允许应用内安装，
/// 「更新」= 重新加载页面（Pages 部署的清单与 Web 站点同源）。
class UpdateInstaller {
  const UpdateInstaller();

  Future<UpdatePlatformInfo> platformInfo() async =>
      const UpdatePlatformInfo(platform: 'web', arch: 'any');

  Future<bool> canInstallPackages() async => true;

  Future<void> openInstallPermissionSettings() async {}

  Future<void> reloadPage() async => _reloadLocation();

  Future<InstallOutcome> installAndRestart({
    required String archivePath,
    required String archiveKind,
  }) async =>
      InstallOutcome.unsupported;
}

/// 仅 Web 编译目标使用：刷新页面以加载新版本。
@JS('location.reload')
external void _reloadLocation();
