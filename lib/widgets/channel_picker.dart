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

/// 全局唯一的渠道选择控件：触发框 + M3E 菜单。
///
/// 为什么不用 `M3EDropdownMenu`：它的弹层宽度被锁成触发框宽度
/// （`m3e_dropdown_menu_panel.dart` 的 `SizedBox(width: renderBox.size.width)`），
/// 旧 item 还给每一行预留右侧打勾槽。手机顶部工具行只有约 115dp，扣掉弹层
/// 内边距 / item 内边距 / 打勾槽后留给渠道名的不到 45dp，四个字以上的内置
/// 平台名（网易云音乐 / 哔哩哔哩）必然只剩「前两个字 + 省略号」。菜单宽度由
/// `anchor + 176` 独立决定（最大 280），渠道名可以在弹层里完整显示；选中态
/// 用菜单自带的前置勾，未选中项不再预留右侧空槽。
///
/// 触发框本身仍要克制：宽度按当前渠道名实测，再由调用方给出上限
/// （发现页要扣掉可见 tab 的槽位，搜索胶囊要给输入框留位置）。超长脚本名
/// 在触发框里允许省略，用户点开菜单即可读到全名。
class ChannelPicker extends StatelessWidget {
  const ChannelPicker({
    super.key,
    required this.channels,
    required this.selectedKey,
    required this.onSelected,
    required this.maxWidth,
    this.surface = ChannelPickerSurface.filled,
    this.focusNode,
    this.semanticLabel,
    this.triggerKey,
  });

  /// 可选择的渠道（调用方负责过滤停用项）。
  final List<SourceDescriptor> channels;

  /// 当前选中的渠道 key。
  final String selectedKey;

  /// 选择渠道。
  final ValueChanged<String> onSelected;

  /// 触发框宽度上限（含内边距）。
  ///
  /// 这是调用方按工具行剩余空间算出的硬上限；实际宽度由渠道名决定，
  /// 不会为了填满而上限而把短名字撑成固定宽。
  final double maxWidth;

  /// 触发框外观。
  final ChannelPickerSurface surface;

  /// 触发框焦点节点（Ctrl+F 的 chip 需要外部节点来还焦点）。
  final FocusNode? focusNode;

  /// 无障碍名；null 时读当前渠道名。
  final String? semanticLabel;

  /// 触发框稳定 Key（测试定位用）。
  final Key? triggerKey;

  @override
  Widget build(BuildContext context) {
    final selected = channels.firstWhere(
      (channel) => channel.key == selectedKey,
      orElse: () => channels.first,
    );
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    final textStyle = m3e.typeScale.bodyMedium.copyWith(
      color: scheme.onSurface,
    );
    final triggerWidth = _triggerWidth(
      context,
      selected.displayName,
      textStyle,
    );

    return M3EMenu(
      anchorBuilder: (context, open) => M3ECard(
        key: triggerKey,
        variant: surface == ChannelPickerSurface.filled
            ? M3ECardVariant.filled
            : M3ECardVariant.outlined,
        // 描边 chip 露出外层搜索胶囊底色；填充面沿用卡片的
        // surfaceContainerHighest，与原下拉框字段同色。
        color: surface == ChannelPickerSurface.outlined
            ? Colors.transparent
            : null,
        elevation: 0,
        borderRadius: BorderRadius.circular(
          surface == ChannelPickerSurface.filled ? 28 : 999,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        width: triggerWidth,
        onPressed: open,
        focusNode: focusNode,
        semanticLabel: semanticLabel ?? selected.displayName,
        child: Row(
          children: [
            Expanded(
              child: Text(
                selected.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textStyle,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 24,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
      selectedValue: selectedKey,
      onSelected: (value) {
        if (value is String) onSelected(value);
      },
      children: [
        for (final channel in channels)
          M3EMenuSelectable(
            label: channel.displayName,
            value: channel.key,
            selected: channel.key == selectedKey,
          ),
      ],
    );
  }

  /// 触发框宽度：文字宽 + 左右内边距 12×2 + 箭头间距 8 + 箭头 24。
  ///
  /// 用 TextPainter 按当前 textScaler 实测而不是估字数：1.5× 字体下
  /// 「网易云音乐」也要尽量完整显示；超过调用方上限时交给 Text 省略。
  double _triggerWidth(BuildContext context, String label, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    // +2：避免亚像素取整后正好触发 ellipsis（TextPainter 与 Text 的
    // 行布局在 0.25px 级可能差一点）。
    final natural = painter.width.ceilToDouble() + 2 + 56;
    painter.dispose();

    final cap = math.max(88.0, maxWidth);
    // 极窄窗口下上限可能低于常规最小宽：以下限不超过上限为准，
    // 否则 clamp 会因 min > max 抛错。
    final floor = math.min(104.0, cap);
    return natural.clamp(floor, cap).toDouble();
  }
}
