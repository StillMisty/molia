import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../utils/responsive.dart';

/// 设置页统一间距常量。
const double kSettingsPadding = 16.0;
const double kSettingsSectionSpacing = 24.0;
const double kSettingsElementSpacing = 16.0;
const double kSettingsSmallSpacing = 8.0;

/// 在设置弹层内部打开子页（不新开弹层）。
///
/// [SettingsPage] 内部有一层 Navigator：这里 push 到最近一层 Navigator，
/// 弹层内使用时即为设置内部导航（返回键先退子页、再关弹层）；独立挂载
/// （测试等）时等价普通页面 push。
Future<T?> openSettingsSubPage<T>(BuildContext context, Widget page) {
  return Navigator.of(context).push<T>(
    MaterialPageRoute<T>(builder: (_) => page),
  );
}

/// 设置弹层内 dialog 的统一宽度（弹层窄于屏幕，弹窗跟随弹层宽度）。
double settingsDialogWidth(BuildContext context) {
  return math.min(
    MediaQuery.sizeOf(context).width * 0.9,
    context.layoutType(ResponsivePageType.modal).modalWidth,
  );
}

/// 设置分组卡片：可选分组标题（卡片上方，结构标签）+ filled 卡片容器。
class SettingsSectionCard extends StatelessWidget {
  const SettingsSectionCard({super.key, this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, kSettingsSmallSpacing),
            child: Text(
              title!,
              style: theme.textTheme.titleMedium?.copyWith(
                // 分组标题是结构标签，不用强调色（强调色只给交互/选中）。
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
        M3ECard(
          variant: M3ECardVariant.filled,
          borderRadius: BorderRadius.circular(kSettingsPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    );
  }
}

/// 导航行：图标 + 标题/副标题 + chevron，点击进入子页或打开弹层。
class SettingsNavTile extends StatelessWidget {
  const SettingsNavTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.isDestructive = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(kSettingsSmallSpacing),
        child: Row(
          children: [
            _SettingsTileIcon(icon: icon, isDestructive: isDestructive),
            const SizedBox(width: kSettingsElementSpacing),
            Expanded(
              child: _SettingsTileLabel(
                title: title,
                subtitle: subtitle,
                isDestructive: isDestructive,
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// 开关行：图标 + 标题/副标题 + M3ESwitch；整行可点。
///
/// [enabled] 为 false 时整项禁用（平台不支持的能力）。
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
  });

  final Key? switchKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled
          ? () {
              HapticFeedback.lightImpact();
              onChanged(!value);
            }
          : null,
      borderRadius: BorderRadius.circular(8),
      child: Opacity(
        opacity: enabled ? 1.0 : 0.45,
        child: Padding(
          padding: const EdgeInsets.all(kSettingsSmallSpacing),
          child: Row(
            children: [
              _SettingsTileIcon(icon: icon, isDestructive: false),
              const SizedBox(width: kSettingsElementSpacing),
              Expanded(
                child: _SettingsTileLabel(title: title, subtitle: subtitle),
              ),
              M3ESwitch(
                key: switchKey,
                value: value,
                onChanged: enabled
                    ? (bool newValue) {
                        HapticFeedback.lightImpact();
                        onChanged(newValue);
                      }
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 只读信息行（无点击、无 chevron）：如「当前播放音质」。
class SettingsInfoTile extends StatelessWidget {
  const SettingsInfoTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(kSettingsSmallSpacing),
      child: Row(
        children: [
          _SettingsTileIcon(icon: icon, isDestructive: false),
          const SizedBox(width: kSettingsElementSpacing),
          Expanded(child: _SettingsTileLabel(title: title, subtitle: subtitle)),
        ],
      ),
    );
  }
}

/// 设置行统一图标底：40dp 圆角块（危险操作走 error 容器成对色）。
class _SettingsTileIcon extends StatelessWidget {
  const _SettingsTileIcon({required this.icon, required this.isDestructive});

  final IconData icon;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isDestructive ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        icon,
        color: isDestructive
            ? scheme.onErrorContainer
            : scheme.onSecondaryContainer,
      ),
    );
  }
}

/// 设置行统一标题/副标题排布。
class _SettingsTileLabel extends StatelessWidget {
  const _SettingsTileLabel({
    required this.title,
    required this.subtitle,
    this.isDestructive = false,
  });

  final String title;
  final String subtitle;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: isDestructive ? scheme.error : scheme.onSurface,
          ),
        ),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
