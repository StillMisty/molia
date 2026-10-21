import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../services/haptics.dart';
import '../../utils/color_hex.dart';
import '../../utils/responsive.dart';
import '../card_list_surface.dart';

/// 设置页统一间距常量。
const double kSettingsPadding = 16.0;
const double kSettingsSectionSpacing = 24.0;
const double kSettingsElementSpacing = 16.0;
const double kSettingsSmallSpacing = 8.0;

/// 设置行统一内边距（标签行 / 复合行同用；行高 token 的计算基准）。
const EdgeInsets kSettingsRowPadding =
    EdgeInsets.symmetric(horizontal: 12, vertical: 8);

/// 下拉字段自适应宽度的上限：选项文案再长也交给省略号，避免把标题挤没。
const double _maxAutoFieldWidth = 240.0;

/// 自适应宽度的余量：字段 / 面板 / 条目的可用宽是多次减法算出来的，刚好等于
/// 量出的文本宽时，浮点舍入可能让条目折行。
const double _autoFieldWidthSlack = 2.0;

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
/// [footer] 是卡片下方的分组说明（如排序规则、空态引导），由调用方给文案。
class SettingsSectionCard extends StatelessWidget {
  const SettingsSectionCard({
    super.key,
    this.title,
    required this.children,
    this.footer,
  });

  final String? title;
  final List<Widget> children;

  /// 卡片下方的说明文字（[SettingsSectionHint] 或任意组件）。
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty && footer == null) return const SizedBox.shrink();
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
        if (footer != null) ...[
          const SizedBox(height: kSettingsSmallSpacing),
          footer!,
        ],
      ],
    );
  }
}

/// 分组说明文字：卡片下方的次要文本（排序规则 / 空态引导等）。
class SettingsSectionHint extends StatelessWidget {
  const SettingsSectionHint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final theme = Theme.of(context);
    return Text(
      text,
      style: m3e.typeScale.bodySmall.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// 分段卡片行容器（M3E 列表规范：行间 `cardList.gap`，行首末外侧 16dp）。
///
/// 用于「一个分组内多行由同一个 widget 产出」的场景（如一个 Selector 里
/// 的多行）；直接作为 [SettingsSectionCard] 子项的行由分组统一下发行形状。
///
/// 行形状必须在这里逐行下发：外层分组只看到「一个子项」（position=single），
/// 不覆盖的话整组都会按 single 画成四角 16dp，与其它分组的首末 16dp /
/// 内行 4dp 不一致（回归见 settings_choice_row_test）。
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
          SettingsRowPosition(
            position: calculateCardPosition(i, children.length),
            child: children[i],
          ),
        ],
      ],
    );
  }
}

/// 设置行统一高度（M3E 列表 token）：有副标题取
/// `M3EListItemTheme.twoLineHeight`（72dp）、无取 `minHeight`（56dp）。
///
/// 副标题封顶 2 行（见 [SettingsTileLabel]），行高不再随文案长度在
/// 56–158dp 之间漂移；内容在行内垂直居中（Row 默认 crossAxisAlignment）。
class _SettingsRowContent extends StatelessWidget {
  const _SettingsRowContent({required this.hasSubtitle, required this.child});

  final bool hasSubtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final item = M3ETheme.of(context).listTheme.item;
    // 行高 token 含行内边距：这里约束的是内边距之内的内容高度
    // （内容在行内垂直居中，图标 40dp 正好撑满无副标题档）。
    final double token = hasSubtitle ? item.twoLineHeight : item.minHeight;
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: token - kSettingsRowPadding.vertical,
      ),
      child: child,
    );
  }
}

/// 复制行：图标 + 标题/副标题 + M3E 复制按钮；点行或按钮都复制并轻反馈
/// （SnackBar 文案由调用方给，内容语义各页不同）。
///
/// [trailing] 追加在复制按钮之前的附属动作（如配对信息的「显示二维码」）。
/// 整行不可点时传 [enabled] = false（只读信息行用 [SettingsInfoTile]）。
class SettingsCopyTile extends StatelessWidget {
  const SettingsCopyTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.copyText,
    required this.copiedMessage,
    this.trailing,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  /// 复制到剪贴板的内容。
  final String copyText;

  /// 复制成功后的 SnackBar 文案。
  final String copiedMessage;

  final Widget? trailing;
  final bool enabled;

  void _copy(BuildContext context) {
    HapticsService.lightImpact();
    Clipboard.setData(ClipboardData(text: copyText));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(copiedMessage)));
  }

  @override
  Widget build(BuildContext context) {
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      semanticLabel: '$title, $subtitle',
      onPressed: enabled ? () => _copy(context) : null,
      child: _SettingsRowContent(
        hasSubtitle: subtitle.isNotEmpty,
        child: Row(
          children: [
            SettingsTileIcon(icon: icon, isDestructive: false),
            const SizedBox(width: 12),
            Expanded(
              child: SettingsTileLabel(title: title, subtitle: subtitle),
            ),
            if (trailing != null) ...[
              const SizedBox(width: kSettingsSmallSpacing),
              trailing!,
            ],
            const SizedBox(width: kSettingsSmallSpacing),
            M3EIconButton(
              icon: const Icon(Icons.content_copy_rounded),
              variant: M3EIconButtonVariant.tonal,
              semanticLabel: copiedMessage,
              onPressed: enabled ? () => _copy(context) : null,
            ),
          ],
        ),
      ),
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
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      semanticLabel: '$title, $subtitle',
      onPressed: onTap == null
          ? null
          : () {
              HapticsService.lightImpact();
              onTap!();
            },
      child: _SettingsRowContent(
        hasSubtitle: subtitle.isNotEmpty,
        child: Row(
          children: [
            SettingsTileIcon(icon: icon, isDestructive: isDestructive),
            const SizedBox(width: 12),
            Expanded(
              child: SettingsTileLabel(
                title: title,
                subtitle: subtitle,
                isDestructive: isDestructive,
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: kSettingsSmallSpacing),
              trailing!,
            ],
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: m3e.colorScheme.onSurfaceVariant,
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
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      semanticLabel: title,
      onPressed: enabled
          ? () {
              HapticsService.lightImpact();
              onChanged(!value);
            }
          : null,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.45,
        child: _SettingsRowContent(
          hasSubtitle: subtitle.isNotEmpty,
          child: Row(
            children: [
              SettingsTileIcon(icon: icon, isDestructive: false),
              const SizedBox(width: 12),
              Expanded(
                child: SettingsTileLabel(
                  title: title,
                  subtitle: subtitle,
                  subtitleColor: subtitleColor,
                ),
              ),
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
      padding: kSettingsRowPadding,
      onPressed: null,
      child: _SettingsRowContent(
        hasSubtitle: subtitle.isNotEmpty,
        child: Row(
          children: [
            SettingsTileIcon(icon: icon, isDestructive: false),
            const SizedBox(width: 12),
            Expanded(
                child: SettingsTileLabel(title: title, subtitle: subtitle)),
          ],
        ),
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
      padding: kSettingsRowPadding,
      semanticLabel: '$title, $value',
      onPressed: () {
        HapticsService.lightImpact();
        onTap();
      },
      child: _SettingsRowContent(
        hasSubtitle: subtitle != null && subtitle!.isNotEmpty,
        child: Row(
          children: [
            SettingsTileIcon(icon: icon, isDestructive: false),
            const SizedBox(width: 12),
            Expanded(
              child: SettingsTileLabel(
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
      ),
    );
  }
}

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

  /// 图标 + 文案的分段：勾替换图标位，选中段不额外变宽。

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
  });

  final IconData icon;
  final String title;
  final String? subtitle;

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
      semanticLabel: title,
      onPressed: null,
      child: _SettingsRowContent(
        hasSubtitle: subtitle != null && subtitle!.isNotEmpty,
        child: Row(
          children: [
            Expanded(
              child: SettingsTileLead(
                  icon: icon, title: title, subtitle: subtitle),
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
                      selected: optionValue == value,
                    ),
                ],
                singleSelect: true,
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
    final fieldNeeded = widestOf(m3e.typeScale.bodyMedium) +
        fieldStyle.padding.resolve(direction).horizontal +
        8 +
        icon;
    // 面板里的选中条目：面板 / 条目内边距 + 对勾图标，文字用条目样式。
    final itemNeeded = widestOf(
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

/// 滑杆行：图标 + 标题/当前值 + 独占整行的滑杆（数值有区间）。
class SettingsSliderRow extends StatelessWidget {
  const SettingsSliderRow({
    super.key,
    required this.icon,
    required this.title,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
  });

  final IconData icon;
  final String title;

  /// 行尾当前值展示（如 `+50 ms` / `80%`）。
  final String valueLabel;

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      semanticLabel: '$title, $valueLabel',
      onPressed: null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: SettingsTileLead(icon: icon, title: title)),
              const SizedBox(width: 8),
              Text(
                valueLabel,
                style: m3e.typeScale.bodyMedium.copyWith(
                  color: m3e.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          M3ESlider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            size: M3ESliderSize.xs,
            trackThickness: 6,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// 颜色值行：色块 + hex 文本 + 编辑图标（点开取色 / 颜色选择面板）。
///
/// hex 在颜色不透明时显示 `#RRGGBB`，带 alpha 时显示 `#AARRGGBB`。
class SettingsColorValueTile extends StatelessWidget {
  const SettingsColorValueTile({
    super.key,
    required this.icon,
    required this.title,
    required this.colorArgb,
    required this.onTap,
  });

  final IconData icon;
  final String title;

  /// 当前颜色（ARGB int；颜色契约禁止页面写 `Color(0x...)` 字面量）。
  final int colorArgb;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final hex = colorHexLabel(
      colorArgb,
      withAlpha: (colorArgb >> 24) & 0xFF != 0xFF,
    );
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      semanticLabel: '$title, $hex',
      onPressed: () {
        HapticsService.lightImpact();
        onTap();
      },
      child: _SettingsRowContent(
        hasSubtitle: false,
        child: Row(
          children: [
            Expanded(child: SettingsTileLead(icon: icon, title: title)),
            const SizedBox(width: 8),
            SettingsColorSwatch(color: Color(colorArgb)),
            const SizedBox(width: 8),
            Text(
              hex,
              style: m3e.typeScale.bodyMedium.copyWith(
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
      ),
    );
  }
}

/// 颜色色块：圆角方块 + 描边（任意颜色都能看清边界，深色主题下尤其重要）。
class SettingsColorSwatch extends StatelessWidget {
  const SettingsColorSwatch({super.key, required this.color, this.size = 24});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: M3ETheme.of(context).colorScheme.outlineVariant),
      ),
    );
  }
}

/// 行首区：图标底 + 标题/副标题（值类型行共用）。
///
/// 内部用 [Expanded] 吃掉剩余宽度把尾部控件推到行尾，因此放在 `Row` 里时
/// 调用方必须再用 `Expanded` 包一层（非 flex 子项拿到的是无界约束）。
///
/// 公开给需要自绘行内容的页面（如音源管理页的状态行）：与内置行共用同一
/// 套图标底 / 排版 / 间距，避免页面各写一份。
class SettingsTileLead extends StatelessWidget {
  const SettingsTileLead({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SettingsTileIcon(icon: icon, isDestructive: false),
        const SizedBox(width: 12),
        Expanded(
          child: SettingsTileLabel(title: title, subtitle: subtitle ?? ''),
        ),
      ],
    );
  }
}

/// 设置行统一图标底：40dp 圆角块（危险操作走 error 容器成对色）。
///
/// [containerColor] / [foregroundColor] 供页面自绘行覆盖成对色（如音源状态行
/// 的成功/错误容器）；缺省走 secondaryContainer 或 errorContainer。
class SettingsTileIcon extends StatelessWidget {
  const SettingsTileIcon({
    super.key,
    required this.icon,
    this.isDestructive = false,
    this.containerColor,
    this.foregroundColor,
  });

  final IconData icon;
  final bool isDestructive;
  final Color? containerColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    // 同目录约定：设置行统一消费 M3ETheme 色板（与 material Theme 的
    // ColorScheme 是两套容器色，混用会出现同屏两种色阶）。
    final scheme = M3ETheme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: containerColor ??
            (isDestructive ? scheme.errorContainer : scheme.secondaryContainer),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        icon,
        color: foregroundColor ??
            (isDestructive
                ? scheme.onErrorContainer
                : scheme.onSecondaryContainer),
      ),
    );
  }
}

/// 设置行统一标题/副标题排布（排版走 M3E typeScale，不写死字号字重）。
///
/// 标题 1 行省略 + 副标题 2 行封顶省略：长副标题不再把行撑到 3 行/158dp，
/// 行高由 [_SettingsRowContent] 统一（有/无副标题 72/56dp）。
class SettingsTileLabel extends StatelessWidget {
  const SettingsTileLabel({
    super.key,
    required this.title,
    required this.subtitle,
    this.isDestructive = false,
    this.subtitleColor,
  });

  final String title;
  final String subtitle;
  final bool isDestructive;

  /// 副标题颜色覆盖（状态色增强；null = 默认次要文本色）。
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: m3e.typeScale.bodyLarge.copyWith(
            color: isDestructive
                ? m3e.colorScheme.error
                : m3e.colorScheme.onSurface,
          ),
        ),
        if (subtitle.isNotEmpty)
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: m3e.typeScale.bodySmall.copyWith(
              color: subtitleColor ?? m3e.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
