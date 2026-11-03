import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 渠道下拉共用的 item builder：文字固定单行，右侧预留固定打勾槽。
///
/// M3E 默认 item 的 label 没有 `maxLines`，选中项多一个 check icon 后窄弹窗
/// 会换行；发现页顶部与 Ctrl+F 搜索条共用这份 builder，保证行高稳定、长名称
/// 只省略不换行。
M3EDropdownItemBuilder<String> channelDropdownItemBuilder(
  BuildContext context,
) {
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
          SizedBox(
            width: 24,
            height: 20,
            child: selected
                ? Icon(Icons.check_rounded, size: 20, color: foreground)
                : null,
          ),
        ],
      ),
    );
  };
}
