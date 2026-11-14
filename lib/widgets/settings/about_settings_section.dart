import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../pages/diagnostics_page.dart';
import '../../pages/update_settings_page.dart';
import '../../providers/update_provider.dart';
import 'settings_section_availability.dart';
import 'settings_tiles.dart';

/// 设置首屏「关于与更新」卡：版本与更新入口 + 问题排查。
///
/// 更新是低频的「检查 / 下载 / 安装」，问题排查是求助入口；两者都不参与
/// 日常播放配置，因此从「通用」卡拆出，放在首屏末位。
class AboutSettingsSection extends StatelessWidget {
  const AboutSettingsSection({super.key, required this.availability});

  final SettingsSectionAvailability availability;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final update = availability.update;
    return SettingsSectionCard(
      title: l10n.settingsUpdateTitle,
      children: [
        // 版本与更新：渠道 / 自动检查 / 下载安装。
        if (update != null)
          SettingsNavTile(
            key: const Key('settingsUpdateItem'),
            icon: Icons.system_update_alt_rounded,
            title: l10n.updateSettingsSection,
            subtitle: _updateSubtitle(l10n, update),
            onTap: () =>
                openSettingsSubPage(context, const UpdateSettingsPage()),
          ),
        SettingsNavTile(
          key: const Key('settingsDiagnosticsItem'),
          icon: Icons.support_agent_rounded,
          title: l10n.diagnosticsTitle,
          subtitle: l10n.diagnosticsSubtitle,
          onTap: () => openSettingsSubPage(context, const DiagnosticsPage()),
        ),
      ],
    );
  }

  /// 更新入口副标题：上次安装未完成优先，其次「可更新至 x.y.z」，否则当前版本。
  String _updateSubtitle(AppLocalizations l10n, UpdateProvider provider) {
    if (provider.installResult == UpdateInstallResult.incomplete) {
      return l10n.updateInstallIncomplete;
    }
    final version = provider.release?.version;
    if (provider.updateAvailable && version != null && version.isNotEmpty) {
      return l10n.settingsUpdateAvailable(version);
    }
    return l10n.settingsUpdateSubtitle(provider.currentVersionLabel);
  }
}
