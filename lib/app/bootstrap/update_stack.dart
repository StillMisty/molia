/// 应用内更新栈：Release 清单 → 下载（sha256 强制校验）→ 平台安装策略
/// （Android 系统安装器 / 桌面替换脚本 / Web 刷新）。
///
/// 版本号来自平台包信息（CI 用 `--build-name/--build-number` 注入，见
/// docs/release.md）；读不到时退化为 0.0.0（仍可检查，只是比较无基准）。
library;

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../data/update/update_downloader.dart';
import '../../data/update/update_manifest_client.dart';
import '../../providers/update_provider.dart';
import '../../services/update/update_installer.dart';
import '../../services/update/update_preferences.dart';
import '../../services/update/update_service.dart';

/// 应用内更新栈产物（构造顺序见 [buildUpdateStack]）。
typedef UpdateStack = ({
  UpdatePreferences preferences,
  UpdateProvider provider,
});

/// 装配更新链路；[quitApp] 是统一退出路径（桌面端替换脚本就绪后由 provider
/// 触发退出，走 flush + 无视关闭策略销毁窗口，否则会被「关闭最小化到托盘」
/// 拦截，替换脚本永远等不到进程退出）。
Future<UpdateStack> buildUpdateStack({
  required Future<void> Function() quitApp,
}) async {
  String appVersion = '0.0.0';
  int appBuild = 0;
  try {
    final packageInfo = await PackageInfo.fromPlatform();
    appVersion = packageInfo.version;
    appBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
  } catch (e) {
    debugPrint('[Molia] 读取应用版本失败（更新检查按 0.0.0 处理）: $e');
  }
  final updatePreferences = UpdatePreferences();
  final updateProvider = UpdateProvider(
    service: UpdateService(
      client: UpdateManifestClient(
        manifestUrlOverride: () => updatePreferences.manifestUrlOverride,
        downloadPrefix: () => updatePreferences.downloadPrefix,
      ),
      downloader: UpdateDownloader(),
      installer: UpdateInstaller(),
    ),
    preferences: updatePreferences,
    currentVersion: appVersion,
    currentBuild: appBuild,
    quitApp: quitApp,
  );
  await updateProvider.init();

  return (preferences: updatePreferences, provider: updateProvider);
}
