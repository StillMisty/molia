import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../pages/diagnostics_page.dart';
import '../../pages/settings_advanced_page.dart';
import '../../pages/update_settings_page.dart';
import '../../providers/update_provider.dart';
import 'settings_section_availability.dart';
import 'settings_tiles.dart';

/// 设置首屏「关于与更新」卡：版本与更新入口 + 问题排查 + 高级设置。
///
/// 更新是低频的「检查 / 下载 / 安装」，问题排查是求助入口，高级设置是
/// 首屏收起项的统一出口；三者都不参与日常播放配置，因此放在首屏末位。
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
        // 可更新只由副标题表达（「可更新至 x.y.z」），不再叠 badge：设置行是
        // 低频入口，行角红点在列表里读起来像未读消息，信息量与文案重复。
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
        // 首屏收起项的统一出口：字体、默认封面、淡入淡出、加入位置、
        // 震动、应用名称、窗口记忆、省流音质、下载与缓存策略、更新地址。
        SettingsNavTile(
          key: const Key('settingsAdvancedItem'),
          icon: Icons.tune_rounded,
          title: l10n.settingsAdvancedTitle,
          subtitle: l10n.settingsAdvancedSubtitle,
          onTap: () =>
              openSettingsSubPage(context, const SettingsAdvancedPage()),
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
