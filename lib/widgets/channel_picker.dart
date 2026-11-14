import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/source.dart' show SourceDescriptor;

/// 渠道选择器的视觉变体。
enum ChannelPickerSurface {
  /// 发现页顶部的填充面：与外层工具行同一套 M3E 卡片观感。
  filled,

  /// 搜索胶囊左侧的描边 chip：透明底 + 胶囊圆角。
  outlined,
}

/// 全局唯一的渠道选择控件：M3E 下拉框 + 与宽度匹配的弹层。
///
/// 为什么回到 `M3EDropdownMenu`：它的字段 / 弹层外观与 App 其它下拉一致
/// （卡片行、圆角面板），比通用 M3E 菜单更贴近渠道选择这种「单选下拉」场景。
/// 它的限制是弹层宽度固定等于字段宽度，所以字段宽度不能只按 32% 屏宽估：
/// 这里按**最长的启用渠道名**实测字段宽度，扣掉弹层内边距 / item 内边距后
/// 仍能放下「网易云音乐 / 哔哩哔哩」这类 5 字内置平台名。
///
/// item 不再为右侧打勾预留固定槽位：只有选中行才显示勾，未选中行把整行
/// 宽度留给渠道名。旧实现给每一行固定预留 24dp，窄弹层里正是只剩
/// 「前两个字 + 省略号」的直接原因。
class ChannelPicker extends StatelessWidget {
  const ChannelPicker({
    super.key,
    required this.channels,
    required this.selectedKey,
    required this.onSelected,
    required this.maxWidth,
    required this.hintText,
    required this.noItemsFoundText,
    this.surface = ChannelPickerSurface.filled,
    this.focusNode,
    this.triggerKey,
  });

  /// 可选择的渠道（调用方负责过滤停用项）。
  final List<SourceDescriptor> channels;

  /// 当前选中的渠道 key。
  final String selectedKey;

  /// 选择渠道。
  final ValueChanged<String> onSelected;

  /// 字段宽度上限（含内边距）。
  ///
  /// 由调用方按工具行剩余空间算出：发现页要扣掉可见 tab 的槽位，搜索胶囊
  /// 要给输入框留位置。弹层宽度跟随字段宽度，所以这个上限同时决定弹层
  /// 能显示多长的渠道名。
  final double maxWidth;

  /// 未选中时的提示文案。
  final String hintText;

  /// 渠道过多开启搜索后，无匹配项时的提示。
  final String noItemsFoundText;

  /// 字段外观。
  final ChannelPickerSurface surface;

  /// 字段焦点节点（Ctrl+F 的 chip 需要外部节点来还焦点）。
  final FocusNode? focusNode;

  /// 字段稳定 Key（测试定位用）。
  final Key? triggerKey;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    final selected = channels.firstWhere(
      (channel) => channel.key == selectedKey,
      orElse: () => channels.first,
    );
    final width = _fieldWidth(context, selected.displayName);

    return SizedBox(
      width: width,
      child: M3EDropdownMenu<String>(
        key: triggerKey,
        focusNode: focusNode,
        items: [
          for (final channel in channels)
            M3EDropdownItem<String>(
              label: channel.displayName,
              value: channel.key,
              selected: channel.key == selectedKey,
            ),
        ],
        singleSelect: true,
        // 单选用纯文本展示（默认 chip 模式点击会取消选中）。
        showChipAnimation: false,
        // 渠道较多（多脚本 / any-listen）时提供搜索过滤。
        searchEnabled: channels.length > 8,
        itemBuilder: _itemBuilder(context),
        fieldStyle: surface == ChannelPickerSurface.filled
            ? M3EDropdownFieldStyle(
                hintText: hintText,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              )
            : M3EDropdownFieldStyle(
                // 透明背景：露出外层搜索胶囊底色，只用描边区分 chip；
                // 聚焦 / 展开时描边略强。
                backgroundColor: Colors.transparent,
                foregroundColor: scheme.onSurface,
                border: BorderSide(color: scheme.outlineVariant),
                focusedBorder: BorderSide(color: scheme.outline),
                borderRadius: BorderRadius.circular(999),
                margin: EdgeInsets.zero,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                hintText: hintText,
                hintStyle: m3e.typeScale.bodyMedium.copyWith(
                  color: scheme.onSurface,
                ),
                selectedTextStyle: m3e.typeScale.bodyMedium.copyWith(
                  color: scheme.onSurface,
                ),
              ),
        dropdownStyle: M3EDropdownPanelStyle(
          noItemsFoundText: noItemsFoundText,
        ),
        onSelectionChanged: (items) {
          if (items.isEmpty) return;
          onSelected(items.first.value);
        },
      ),
    );
  }

  /// 下拉 item：未选中行不再预留右侧打勾槽，只有选中行显示勾。
  ///
  /// 选中态沿用 M3E 的 itemSelectedBackgroundColor；勾只占选中行自己的
  /// 宽度，窄弹层里其它行可以把整行宽度让给渠道名。
  M3EDropdownItemBuilder<String> _itemBuilder(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    final menuTheme = m3e.dropdownMenuTheme;
    final textStyle = menuTheme.itemTextStyle(m3e.typeScale, scheme);
    return (item, {required selected, required onTap}) {
      final background = selected
          ? menuTheme.itemSelectedBackgroundColor(scheme)
          : menuTheme.itemBackgroundColor(scheme);
      final foreground = selected
          ? menuTheme.itemSelectedForegroundColor(scheme)
          : menuTheme.itemForegroundColor(scheme);
      return M3ECard(
        variant: M3ECardVariant.filled,
        color: background,
        elevation: 0,
        borderRadius: BorderRadius.circular(12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        width: double.infinity,
        onPressed: item.disabled ? null : onTap,
        child: Row(
          children: [
            Expanded(
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textStyle.copyWith(color: foreground),
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 8),
              Icon(Icons.check_rounded, size: 20, color: foreground),
            ],
          ],
        ),
      );
    };
  }

  /// 字段宽度：取「最长渠道名」在弹层里的需求，与当前选中名的字段需求
  /// 取较大值。
  ///
  /// 弹层宽度 = 字段宽度，弹层左右各 8、item 左右各 16，所以最长名 +
  /// 48 才能完整显示；字段本身还要容纳 bodyMedium 文字 + 左右 12 + 8 间距
  /// + 24 箭头。两个公式都按当前 textScaler 实测，1.5× 字体不会靠猜。
  double _fieldWidth(BuildContext context, String selectedLabel) {
    final m3e = M3ETheme.of(context);
    var widestItem = 0.0;
    for (final channel in channels) {
      widestItem = math.max(
        widestItem,
        _textWidth(context, channel.displayName, m3e.typeScale.bodyLarge),
      );
    }
    final selectedWidth = _textWidth(
      context,
      selectedLabel,
      m3e.typeScale.bodyMedium,
    );
    // 弹层里选中行右侧还有 8 间距 + 20 勾；未选中行不再预留这个槽位。
    final selectedCheck = channels.any((c) => c.key == selectedKey)
        ? 28.0
        : 0.0;
    // +2：避免亚像素取整后正好触发 ellipsis。
    final natural =
        math.max(widestItem + 48 + selectedCheck, selectedWidth + 56) + 2;

    final cap = math.max(88.0, maxWidth);
    // 极窄窗口下上限可能低于常规最小宽：以下限不超过上限为准，
    // 否则 clamp 会因 min > max 抛错。
    final floor = math.min(104.0, cap);
    return natural.clamp(floor, cap).toDouble();
  }

  double _textWidth(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}
