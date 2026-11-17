import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../../services/haptics.dart';
import 'settings_tiles_support.dart';

/// 开关行：图标 + 标题/副标题 + M3ESwitch；整行可点。
///
/// [enabled] 为 false 时整项禁用（平台不支持的能力）。
/// [trailing] 追加在开关之后的附属控件（如底部导航行的拖拽手柄）。
class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    super.key,
    this.switchKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.trailing,
    this.subtitleColor,
  });

  final Key? switchKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;
  final Widget? trailing;

  /// 副标题颜色覆盖（状态色增强；null = 默认次要文本色）。
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) {
    return SettingsTileRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      subtitleColor: subtitleColor,
      enabled: enabled,
      onPressed: enabled
          ? () {
              HapticsService.lightImpact();
              onChanged(!value);
            }
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          M3ESwitch(
            key: switchKey,
            value: value,
            onChanged: enabled
                ? (bool newValue) {
                    HapticsService.lightImpact();
                    onChanged(newValue);
                  }
                : null,
          ),
          if (trailing != null) ...[
            const SizedBox(width: kSettingsSmallSpacing),
            trailing!,
          ],
        ],
      ),
    );
  }
}
