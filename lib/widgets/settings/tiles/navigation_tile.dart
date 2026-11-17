import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../../services/haptics.dart';
import 'settings_tiles_support.dart';

/// 导航行：图标 + 标题/副标题 + chevron，点击进入子页或打开弹层。
class SettingsNavTile extends StatelessWidget {
  const SettingsNavTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.isDestructive = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  /// chevron 之前的附属控件（如「Aa」字体样例）；缺省只有 chevron。
  final Widget? trailing;

  /// 为 null 时整行禁用（如清理进行中）。
  final VoidCallback? onTap;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    return SettingsTileRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      isDestructive: isDestructive,
      onPressed: onTap == null
          ? null
          : () {
              HapticsService.lightImpact();
              onTap!();
            },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailing != null) ...[
            trailing!,
            const SizedBox(width: kSettingsSmallSpacing),
          ],
          Icon(
            Icons.chevron_right_rounded,
            size: kSettingsTileActionSize,
            color: m3e.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}
