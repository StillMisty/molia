import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../pages/shortcut_settings_page.dart';
import '../../services/window/window_settings.dart';
import 'settings_section_availability.dart';
import 'settings_tiles.dart';

/// 设置首屏「桌面」卡：关闭到托盘 / 记住窗口位置 / 快捷键。
///
/// 只在桌面平台出现（由首屏决定是否挂载）：移动端没有托盘与窗口，放一行
/// 置灰的入口只会制造困惑。托盘与窗口是设备本地键，卡底给一句说明。
class DesktopSettingsSection extends StatelessWidget {
  const DesktopSettingsSection({super.key, required this.availability});

  final SettingsSectionAvailability availability;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 托盘能力或设置缺省时不显示托盘 / 窗口行（Linux 精简桌面可能没有托盘）。
    final tray = availability.tray;
    return SettingsSectionCard(
      title: l10n.settingsDesktopSection,
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (availability.trayLinuxHintVisible) ...[
            SettingsSectionHint(text: l10n.settingsTrayLinuxHint),
            const SizedBox(height: 4),
          ],
          SettingsSectionHint(text: l10n.settingsDesktopDeviceLocalHint),
        ],
      ),
      children: [
        if (availability.trayRowsVisible && tray != null) ...[
          SettingsSwitchTile(
            switchKey: const Key('settingsCloseToTraySwitch'),
            icon: Icons.desktop_windows_rounded,
            title: l10n.settingsCloseToTray,
            subtitle: l10n.settingsCloseToTraySubtitle,
            value: tray.closeToTray,
            onChanged: tray.setCloseToTray,
          ),
          ValueListenableBuilder<bool>(
            valueListenable: WindowSettings.rememberBoundsNotifier,
            builder: (context, rememberBounds, _) => SettingsSwitchTile(
              switchKey: const Key('settingsRememberWindowBoundsSwitch'),
              icon: Icons.window_rounded,
              title: l10n.settingsRememberWindowBounds,
              subtitle: l10n.settingsRememberWindowBoundsSubtitle,
              value: rememberBounds,
              onChanged: WindowSettings.setRememberBounds,
            ),
          ),
        ],
        // 快捷键：软件内 / 全局两组的总开关与绑定自定义。桌面独占。
        SettingsNavTile(
          key: const Key('settingsShortcutsItem'),
          icon: Icons.keyboard_rounded,
          title: l10n.settingsShortcutsTitle,
          subtitle: l10n.settingsShortcutsSubtitle,
          onTap: () =>
              openSettingsSubPage(context, const ShortcutSettingsPage()),
        ),
      ],
    );
  }
}
