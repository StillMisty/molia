import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../card_list_surface.dart';
import 'settings_tiles.dart';

/// 可视化选择项：值 + 名称 + 预览图形（[SettingsSwatchRow] 内 56dp 圆）。
class SettingsSwatchOption<T> {
  const SettingsSwatchOption({
    required this.value,
    required this.label,
    required this.swatch,
    this.supportingText,
  });

  final T value;

  /// 预览圆下方的名称。
  final String label;

  /// 名称下方的补充信息（如自定义色 hex）。
  final String? supportingText;

  /// 预览图形：在 56dp 紧约束内自绘（被 [ClipOval] 裁成圆形）。
  final Widget swatch;
}

/// 可视化单选行：图标 + 标题/副标题 + swatch 横排（「所见即所选」的枚举）。
///
/// 形态对齐 M3E 主题配置示例：56dp 圆形预览 + 名称在下；选中 3dp
/// `onSurface` 描边 + 对勾，未选中 1dp `outlineVariant`；按压 0.94 缩放 +
/// 轻震。适合带预览的枚举（主题模式 / 基础配色 / 歌词配色），纯文字枚举
/// 仍走 [SettingsChoiceRow]。
///
/// 对勾画在 `surfaceContainerHigh` 小圆里（颜色契约禁黑白字面量）：
/// 任意底色上 「容器 + onSurface 图标」都成对可读，无需按底色判对比色。
class SettingsSwatchRow<T> extends StatelessWidget {
  const SettingsSwatchRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.options,
    required this.onChanged,
    this.optionEnabled,
  }) : assert(options.length >= 2, '可视化选择行至少 2 个选项。');

  final IconData icon;
  final String title;
  final String? subtitle;

  /// 当前值（不在 [options] 中时全部显示为未选中）。
  final T value;

  final List<SettingsSwatchOption<T>> options;

  final ValueChanged<T> onChanged;

  /// 单项禁用判定（如平台能力不足的选项）；缺省全部可用。
  final bool Function(T value)? optionEnabled;

  @override
  Widget build(BuildContext context) {
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      semanticLabel: title,
      onPressed: null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsTileLead(icon: icon, title: title, subtitle: subtitle),
          const SizedBox(height: kSettingsSmallSpacing),
          Wrap(
            spacing: kSettingsElementSpacing,
            runSpacing: kSettingsSmallSpacing,
            children: [
              for (final option in options)
                _SwatchOption<T>(
                  option: option,
                  selected: option.value == value,
                  enabled: optionEnabled?.call(option.value) ?? true,
                  onTap: () => onChanged(option.value),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 单个 swatch 选项：预览圆（描边 + 选中对勾叠层）+ 名称（+ 补充信息）。
class _SwatchOption<T> extends StatelessWidget {
  const _SwatchOption({
    required this.option,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final SettingsSwatchOption<T> option;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  /// 预览圆直径（M3E 主题配置示例同值）。
  static const double _size = 56;

  /// 选中对勾底圆直径。
  static const double _checkBadgeSize = 24;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    final supportingText = option.supportingText;
    return M3ETappable(
      onTap: enabled ? onTap : null,
      enabled: enabled,
      semanticLabel: supportingText == null
          ? option.label
          : '${option.label}, $supportingText',
      // 单选候选：语义按「单选组里的可勾选项」上报，选中态由行权威。
      semanticButton: false,
      semanticChecked: selected,
      semanticInMutuallyExclusiveGroup: true,
      pressedScale: 0.94,
      haptic: M3EHapticFeedback.light,
      builder: (context, _) => Opacity(
        // 禁用（平台能力不足）与设置开关行的 0.45 同档。
        opacity: enabled ? 1.0 : 0.45,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: _size,
              height: _size,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipOval(child: option.swatch),
                  // 描边画在缩放层之上：按压缩放时边框与内容一起缩（是同一个 Stack）。
                  AnimatedContainer(
                    duration: M3EMotion.short3,
                    curve: M3EMotion.standard,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected
                            ? scheme.onSurface
                            : scheme.outlineVariant,
                        width: selected ? 3 : 1,
                      ),
                    ),
                  ),
                  if (selected)
                    Center(
                      child: Container(
                        width: _checkBadgeSize,
                        height: _checkBadgeSize,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: scheme.surfaceContainerHigh,
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Icon(
                          Icons.check_rounded,
                          size: 16,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: kSettingsSmallSpacing),
            Text(
              option.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: m3e.typeScale.labelMedium.copyWith(
                color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
            ),
            if (supportingText != null)
              Text(
                supportingText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: m3e.typeScale.labelSmall.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
