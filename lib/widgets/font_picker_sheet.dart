import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../services/system_fonts_service.dart';
import 'app_search_bar.dart';
import 'card_list_surface.dart';

/// AppLocalizations 查找：与收藏页同一约定，测试未注册 delegate 时回退中文。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 字体选择结果。
///
/// - [FontChoice.inherit]：清除覆盖，跟随入口既定默认（设置页不提供，
///   海报页语义为「跟随应用字体」）；
/// - [FontChoice.system]：显式使用系统默认字体；
/// - [FontChoice.family]：使用设备上的指定字体族。
class FontChoice {
  const FontChoice.inherit()
      : inherit = true,
        family = null;

  const FontChoice.system()
      : inherit = false,
        family = null;

  const FontChoice.family(String this.family) : inherit = false;

  /// 是否为「继承入口默认」选择。
  final bool inherit;

  /// 字体族名；null 表示系统默认（或继承）。
  final String? family;
}

/// 字体选择弹层：内置「系统默认」+ 设备已装字体列表（含搜索与字体名预览）。
///
/// 设备字体枚举由 [SystemFontsService] 提供；取消返回 null。
/// [includeInherit] 为 true 时列表首项是「继承」（[inheritLabel] 自定义文案）。
/// [loadFamilies] 仅测试注入用。
Future<FontChoice?> showFontPickerSheet(
  BuildContext context, {
  required String title,
  FontChoice? selected,
  bool includeInherit = false,
  String? inheritLabel,
  Future<List<String>> Function()? loadFamilies,
}) {
  return M3EBottomSheet.show<FontChoice>(
    context,
    builder: (_) => _FontPickerSheet(
      title: title,
      selected: selected,
      includeInherit: includeInherit,
      inheritLabel: inheritLabel,
      loadFamilies: loadFamilies ?? SystemFontsService.listFamilies,
    ),
  );
}

class _FontPickerSheet extends StatefulWidget {
  const _FontPickerSheet({
    required this.title,
    required this.selected,
    required this.includeInherit,
    required this.inheritLabel,
    required this.loadFamilies,
  });

  final String title;
  final FontChoice? selected;
  final bool includeInherit;
  final String? inheritLabel;
  final Future<List<String>> Function() loadFamilies;

  @override
  State<_FontPickerSheet> createState() => _FontPickerSheetState();
}

class _FontPickerSheetState extends State<_FontPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  List<String>? _families;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadFamilies();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadFamilies() async {
    final families = await widget.loadFamilies();
    if (!mounted) return;
    setState(() => _families = families);
  }

  bool _isSelected(FontChoice choice) {
    final selected = widget.selected;
    if (selected == null) return false;
    return choice.inherit == selected.inherit && choice.family == selected.family;
  }

  void _pop(FontChoice choice) => Navigator.of(context).pop(choice);

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    final families = _families;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: Text(widget.title, style: theme.textTheme.titleMedium),
          ),
          // 字体较多时（iOS 等）提供搜索，避免长列表滚动找字体。
          if (families != null && families.length > 15)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: AppSearchBar(
                controller: _searchController,
                hintText: l10n.fontPickerSearchHint,
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
              ),
            ),
          Flexible(
            child: switch (families) {
              null => const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: M3ELoadingIndicator()),
                ),
              [] => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    l10n.fontPickerEmpty,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              final list => _buildFamilyList(context, l10n, list),
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 设备字体列表：分段卡片行 + M3E 行距，形状随首末行变化。
  ///
  /// 用 `ListView.separated` 而不是手写 `children`：行距取主题
  /// `cardList.gap`，且行位置（首/中/末）要按过滤后的实际数量计算——
  /// 先构造选项表，再在 itemBuilder 里算位置，搜索过滤后形状仍然正确。
  Widget _buildFamilyList(
    BuildContext context,
    AppLocalizations l10n,
    List<String> families,
  ) {
    final options = <({String label, String? family, FontChoice choice})>[
      if (widget.includeInherit)
        (
          label: widget.inheritLabel ?? l10n.posterFontFollowApp,
          family: null,
          choice: const FontChoice.inherit(),
        ),
      (
        label: l10n.fontSystemDefault,
        // 预览必须是真正的系统默认字体，而不是当前主题里已选中的「应用
        // 字体」——否则选了自定义字体后，用户会误以为「系统默认」也是
        // 这个字体。
        family: SystemFontsService.platformDefaultFamily,
        choice: const FontChoice.system(),
      ),
      for (final family in families)
        if (_query.isEmpty || family.toLowerCase().contains(_query))
          (
            label: family,
            family: family,
            choice: FontChoice.family(family),
          ),
    ];
    final gap = M3ETheme.of(context).listTheme.cardList.gap;
    return ListView.separated(
      shrinkWrap: true,
      itemCount: options.length,
      separatorBuilder: (BuildContext context, int index) =>
          SizedBox(height: gap),
      itemBuilder: (BuildContext context, int index) {
        final option = options[index];
        return _FontOptionTile(
          label: option.label,
          family: option.family,
          selected: _isSelected(option.choice),
          position: calculateCardPosition(index, options.length),
          onTap: () => _pop(option.choice),
        );
      },
    );
  }
}

/// 字体选项行：字体名用其自身字体渲染，便于直接预览效果。
class _FontOptionTile extends StatelessWidget {
  const _FontOptionTile({
    required this.label,
    this.family,
    required this.selected,
    required this.position,
    required this.onTap,
  });

  final String label;
  final String? family;
  final bool selected;
  final M3ECardPosition position;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    // 排版走 M3E typeScale（不写死字号）；字体预览只覆盖 fontFamily。
    // 选中态用 primary + w500，不写死 w600（M3E 的选中强调是颜色 + 一档
    // 字重，不是跳两级）。
    final style = m3e.typeScale.bodyLarge.copyWith(
      fontFamily: family,
      color: selected ? scheme.primary : scheme.onSurface,
      fontWeight: selected ? FontWeight.w500 : null,
    );
    return CardListSurface(
      position: position,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      onPressed: onTap,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          if (selected)
            Icon(Icons.check_rounded, color: scheme.primary, size: 20),
        ],
      ),
    );
  }
}
