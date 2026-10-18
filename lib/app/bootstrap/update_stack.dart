/// 应用内更新栈：Release 清单 → 下载（sha256 强制校验）→ 平台安装策略
/// （Android 系统安装器 / 桌面替换脚本）。
///
/// 纯构造（无 IO）：版本号来自平台包信息（CI 用 `--build-name/--build-number`
/// 注入，见 `.agents/skills/molia-release/SKILL.md`），包信息 / 偏好 / 平台信息
/// 的读取收在 [UpdateProvider.start] 里，由组合根在**首帧之后**调用——它们
/// 都不参与首帧内容（见 `post_frame_init.dart`）。
library;

import '../../data/update/update_downloader.dart';
import '../../data/update/update_manifest_client.dart';
import '../../providers/update_provider.dart';
import '../../services/update/update_installer.dart';
import '../../services/update/update_preferences.dart';
import '../../services/update/update_service.dart';

/// 更新栈产物（构造顺序见 [buildUpdateStack]）。
typedef UpdateStack = ({
  UpdatePreferences preferences,
  UpdateProvider provider,
});

/// 装配更新链路；[quitApp] 是统一退出路径（桌面端替换脚本就绪后由 provider
/// 触发退出，走 flush + 无视关闭策略销毁窗口，否则会被「关闭最小化到托盘」
/// 拦截，替换脚本永远等不到进程退出）。
UpdateStack buildUpdateStack({
  required Future<void> Function() quitApp,
}) {
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
    quitApp: quitApp,
  );

  return (preferences: updatePreferences, provider: updateProvider);
}
