import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../card_list_surface.dart';
import 'settings_tiles_support.dart';

/// 下拉字段自适应宽度的上限：选项文案再长也交给省略号，避免把标题挤没。
const double _maxAutoFieldWidth = 240.0;

/// 自适应宽度的余量：字段 / 面板 / 条目的可用宽是多次减法算出来的，刚好等于
/// 量出的文本宽时，浮点舍入可能让条目折行。
const double _autoFieldWidthSlack = 2.0;

/// 下拉行：图标 + 标题/副标题 + 行尾下拉菜单（≥5 项或长文案的枚举）。
///
/// 单选必须给 `fieldStyle.hintText`：缺省时未选中会显示包内英文兜底
/// `Select`（与页面语言不符）。
class SettingsDropdownRow<T> extends StatelessWidget {
  const SettingsDropdownRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.options,
    required this.onChanged,
    this.dropdownKey,
    this.fieldWidth = 170,
    this.enabled = true,
    this.optionEnabled,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// 整行禁用（被上游开关接管的从属设置）：置灰 + 字段不可展开。
  final bool enabled;

  /// 单项禁用判定（平台能力不足的选项；与 `SettingsChoiceRow` 同一语义）。
  final bool Function(T value)? optionEnabled;

  /// 行尾下拉字段宽度（默认 170）：是**最小**宽度，选项文案更长时按最长选项
  /// 自动加宽（见 [_resolvedFieldWidth]），避免「Hi-Res」/「Lossless」折行。
  final double fieldWidth;

  /// 当前值（不在 [options] 中时字段回落为 [title] 提示文案）。
  final T value;

  /// 选项（值 + 显示文案）。
  final List<(T, String)> options;

  final ValueChanged<T> onChanged;

  /// 下拉控件自身的 Key（测试 / 定位用；行容器另有调用方 Key）。
  final Key? dropdownKey;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final selectedTextStyle = m3e.dropdownMenuTheme.selectedTextStyle(
      m3e.typeScale,
      m3e.colorScheme,
    );
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      semanticLabel: subtitle == null || subtitle!.isEmpty
          ? title
          : '$title, $subtitle',
      onPressed: null,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.45,
        child: SettingsRowContent(
          hasSubtitle: subtitle != null && subtitle!.isNotEmpty,
          child: Row(
            children: [
              Expanded(
                child: SettingsTileLead(
                  icon: icon,
                  title: title,
                  subtitle: subtitle,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                // 设置弹层窄于屏幕：字段定宽，避免撑挤标题；但不能窄到折行。
                width: _resolvedFieldWidth(context),
                child: M3EDropdownMenu<T>(
                  key: dropdownKey,
                  items: [
                    for (final (optionValue, label) in options)
                      M3EDropdownItem<T>(
                        label: label,
                        value: optionValue,
                        disabled: !(optionEnabled?.call(optionValue) ?? true),
                        selected: optionValue == value,
                      ),
                  ],
                  singleSelect: true,
                  enabled: enabled,
                  showChipAnimation: false,
                  fieldStyle: M3EDropdownFieldStyle(
                    hintText: title,
                    selectedTextStyle: selectedTextStyle,
                  ),
                  // M3E 字段的默认选中文本只带省略号、没有 `maxLines`：宽度不足
                  // 时「Hi-Res」会从连字符处折成两行顶高整行。这里自带单行文本，
                  // 折行在结构上不可能发生（宽度不足由省略号接管）。
                  selectedItemBuilder: (item) => Text(
                    item.label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: selectedTextStyle,
                  ),
                  onSelectionChanged: (items) {
                    if (items.isNotEmpty) onChanged(items.first.value);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 字段实际宽度：放得下最长选项（含系统字体缩放），但不小于 [fieldWidth]。
  ///
  /// 为什么必须量：下拉面板宽度 = 字段宽度，而选中值在面板里比字段里**更窄**
  /// ——面板内容内边距 8×2 + 条目内边距 16×2 + 选中对勾图标，且条目文字大一档
  /// （`itemTextStyle` = bodyLarge）。宽度不足时 M3E 的文本没有 `maxLines`，
  /// 「Hi-Res」会从连字符处折成两行（字段侧另见 `selectedItemBuilder` 的单行
  /// 兜底）。度量口径与字段 / 面板 / 条目内部一致，内边距从默认样式对象取，
  /// 包升级后不会与实现漂移；上限 [_maxAutoFieldWidth] 保证标题不被长选项挤没。
  double _resolvedFieldWidth(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double widestOf(TextStyle style) {
      var widest = 0.0;
      for (final (_, label) in options) {
        final painter = TextPainter(
          text: TextSpan(text: label, style: style),
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        widest = math.max(widest, painter.width);
      }
      return widest;
    }

    const fieldStyle = M3EDropdownFieldStyle();
    const panelStyle = M3EDropdownPanelStyle();
    const itemStyle = M3EDropdownItemStyle();
    // 字段箭头 / 条目对勾都是无显式尺寸的 Icon：实际宽度 = 环境 IconTheme 解析
    // 结果（框架对未设置的尺寸回退 24），M3E 主题的 iconTheme 可能不带尺寸。
    final icon = IconTheme.of(context).size ?? 24;
    // 字段：选中文本 + 左右内边距 + 与箭头的 8 间距 + 箭头图标。
    final fieldNeeded =
        widestOf(m3e.typeScale.bodyMedium) +
        fieldStyle.padding.resolve(direction).horizontal +
        8 +
        icon;
    // 面板里的选中条目：面板 / 条目内边距 + 对勾图标，文字用条目样式。
    final itemNeeded =
        widestOf(
          itemStyle.textStyle ??
              m3e.dropdownMenuTheme.itemTextStyle(
                m3e.typeScale,
                m3e.colorScheme,
              ),
        ) +
        panelStyle.contentPadding.resolve(direction).horizontal +
        itemStyle.itemPadding.resolve(direction).horizontal +
        icon;
    return math.max(
      fieldWidth,
      math.min(
        math.max(fieldNeeded, itemNeeded) + _autoFieldWidthSlack,
        _maxAutoFieldWidth,
      ),
    );
  }
}
