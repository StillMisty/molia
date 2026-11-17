import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../card_list_surface.dart';
import 'settings_tiles_support.dart';

/// 单选行：图标 + 标题/副标题 + 独占整行的分段按钮（枚举 2–5 项短文案）。
///
/// 为什么分段按钮独占整行且显式宽度：`M3ESegmentedButton` 内部是
/// `Stack` + `Positioned.fill` + `Row(mainAxisSize.min)`，在放松约束的父级
/// （`Align` / `Row` 尾位）会塌成零宽并溢出；这里把它放进
/// `double.infinity` 的紧约束里，多个 segment 才会等宽铺满。
///
/// M3E 选中形态（[icons] 提供时）：选中段的图标位置改画对勾（勾替换图标，
/// 不额外占宽）。只在「图标 + 文案」放得下的行使用（2–3 段、短标签：对齐 /
/// 更新渠道）；长标签（Sequential / Single repeat / Song title）加图标会把
/// 文案挤到截断，保持纯文字分段——勾 + 长文案同理（回归见
/// settings_choice_row_test）。
class SettingsChoiceRow<T> extends StatelessWidget {
  const SettingsChoiceRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.options,
    required this.onChanged,
    this.optionEnabled,
    this.icons,
    this.enabled = true,
  }) : assert(
         options.length >= 2 && options.length <= 5,
         '分段行需要 2–5 个选项（更多选项请用 SettingsDropdownRow）。',
       );

  final IconData icon;
  final String title;
  final String? subtitle;

  /// 当前值（不在 [options] 中时显示为未选中）。
  final T value;

  /// 选项（值 + 显示文案）。
  final List<(T, String)> options;

  /// 逐项图标：选项文案放得下时使用（图标 + 文案，选中段对勾替换图标）；
  /// 缺省 / 不齐时保持纯文字分段（勾会挤占标签宽度）。
  final Map<T, IconData>? icons;

  final ValueChanged<T> onChanged;

  /// 单项禁用判定（如平台能力不足的选项）；缺省全部可用。
  final bool Function(T value)? optionEnabled;

  /// 整行禁用（被上游开关接管的从属设置）；置灰 + 全部选项不可点。
  final bool enabled;

  /// 是否处于 M3E 选中形态：每个选项都配了图标。
  bool get _showSelectedIcon =>
      icons != null && options.every((option) => icons!.containsKey(option.$1));

  @override
  Widget build(BuildContext context) {
    final selected = options.any((option) => option.$1 == value)
        ? <T>{value}
        : <T>{};
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      semanticLabel: title,
      onPressed: null,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.45,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsTileLead(icon: icon, title: title, subtitle: subtitle),
            const SizedBox(height: kSettingsSmallSpacing),
            SizedBox(
              width: double.infinity,
              child: M3ESegmentedButton<T>(
                // 只有逐项图标齐全时才显示选中勾（勾替换图标、不占额外宽度）；
                // 纯文字分段的勾会把标签挤到截断（「System …」），见类注释。
                showSelectedIcon: _showSelectedIcon,
                segments: [
                  for (final (optionValue, label) in options)
                    M3ESegment<T>(
                      value: optionValue,
                      label: label,
                      icon: icons?[optionValue] == null
                          ? null
                          : Icon(icons![optionValue]!),
                      enabled: optionEnabled?.call(optionValue) ?? true,
                    ),
                ],
                selected: selected,
                enabled: enabled,
                onSelectionChanged: (selection) {
                  if (selection.isNotEmpty) onChanged(selection.first);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
