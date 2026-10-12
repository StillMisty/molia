import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../utils/responsive.dart';
import '../card_list_surface.dart';

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

/// 分段行位置：由 [SettingsSectionCard] 按子项下标下发（M3E 列表卡片形状：
/// 内行 4dp / 首末外侧 16dp）。子项自行构造时缺省为 single。
class SettingsRowPosition extends InheritedWidget {
  const SettingsRowPosition({
    super.key,
    required this.position,
    required super.child,
  });

  final M3ECardPosition position;

  static M3ECardPosition of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<SettingsRowPosition>()
          ?.position ??
      M3ECardPosition.single;

  @override
  bool updateShouldNotify(SettingsRowPosition oldWidget) =>
      oldWidget.position != position;
}

/// 设置分组：标题 + 分段卡片行（M3E 列表规范：行间 `cardList.gap`）。
///
/// 行表面由各 tile 经 [CardListSurface] 自绘（形状按分组内位置：内行 4dp、
/// 首末外侧 16dp；hover 12dp、press 16dp，形状走 spatial 弹簧）。
class SettingsSectionCard extends StatelessWidget {
  const SettingsSectionCard({super.key, this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final m3e = M3ETheme.of(context);
    final gap = m3e.listTheme.cardList.gap;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, kSettingsSmallSpacing),
            child: Text(
              title!,
              style: m3e.typeScale.titleSmall.copyWith(
                // 分组标题是结构标签，不用强调色（强调色只给交互/选中）。
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          SettingsRowPosition(
            position: calculateCardPosition(i, children.length),
            child: children[i],
          ),
        ],
      ],
    );
  }
}

/// 分段卡片行容器（M3E 列表规范：行间 `cardList.gap`，行首末外侧 16dp）。
///
/// 用于「一个分组内多行由同一个 widget 产出」的场景（如一个 Selector 里
/// 的多行）；直接作为 [SettingsSectionCard] 子项的行由分组统一下发行形状。
class SettingsRows extends StatelessWidget {
  const SettingsRows({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final gap = M3ETheme.of(context).listTheme.cardList.gap;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          children[i],
        ],
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

  /// 为 null 时整行禁用（如清理进行中）。
  final VoidCallback? onTap;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      semanticLabel: '$title, $subtitle',
      onPressed: onTap == null
          ? null
          : () {
              HapticFeedback.lightImpact();
              onTap!();
            },
      child: Row(
        children: [
          _SettingsTileIcon(icon: icon, isDestructive: isDestructive),
          const SizedBox(width: 12),
          Expanded(
            child: _SettingsTileLabel(
              title: title,
              subtitle: subtitle,
              isDestructive: isDestructive,
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: m3e.colorScheme.onSurfaceVariant,
          ),
        ],
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
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      semanticLabel: title,
      onPressed: enabled
          ? () {
              HapticFeedback.lightImpact();
              onChanged(!value);
            }
          : null,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.45,
        child: Row(
          children: [
            _SettingsTileIcon(icon: icon, isDestructive: false),
            const SizedBox(width: 12),
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
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      onPressed: null,
      child: Row(
        children: [
          _SettingsTileIcon(icon: icon, isDestructive: false),
          const SizedBox(width: 12),
          Expanded(child: _SettingsTileLabel(title: title, subtitle: subtitle)),
        ],
      ),
    );
  }
}

/// 值行（可编辑/可选）：图标 + 标题/副标题 + 当前值 + 编辑图标。
///
/// 缓存策略等「点开弹层改一个值」的设置项共用。
class SettingsValueTile extends StatelessWidget {
  const SettingsValueTile({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String title;

  /// 当前值展示（行尾，次要文本色）。
  final String value;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      semanticLabel: '$title, $value',
      onPressed: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Row(
        children: [
          _SettingsTileIcon(icon: icon, isDestructive: false),
          const SizedBox(width: 12),
          Expanded(
            child: _SettingsTileLabel(
              title: title,
              subtitle: subtitle ?? '',
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: m3e.typeScale.bodyMedium.copyWith(
              // 当前值是信息文本，不用强调色。
              color: m3e.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.edit_rounded,
            size: 18,
            color: m3e.colorScheme.onSurfaceVariant,
          ),
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
        borderRadius: BorderRadius.circular(12),
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

/// 设置行统一标题/副标题排布（排版走 M3E typeScale，不写死字号字重）。
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
    final m3e = M3ETheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: m3e.typeScale.bodyLarge.copyWith(
            color: isDestructive
                ? m3e.colorScheme.error
                : m3e.colorScheme.onSurface,
          ),
        ),
        if (subtitle.isNotEmpty)
          Text(
            subtitle,
            style: m3e.typeScale.bodySmall.copyWith(
              color: m3e.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
