import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../services/system_fonts_service.dart';
import 'app_search_bar.dart';

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
              final list => ListView(
                  shrinkWrap: true,
                  children: [
                    if (widget.includeInherit)
                      _FontOptionTile(
                        label: widget.inheritLabel ?? l10n.posterFontFollowApp,
                        selected: _isSelected(const FontChoice.inherit()),
                        onTap: () => _pop(const FontChoice.inherit()),
                      ),
                    _FontOptionTile(
                      label: l10n.fontSystemDefault,
                      selected: _isSelected(const FontChoice.system()),
                      onTap: () => _pop(const FontChoice.system()),
                    ),
                    for (final family in list)
                      if (_query.isEmpty ||
                          family.toLowerCase().contains(_query))
                        _FontOptionTile(
                          label: family,
                          family: family,
                          selected: _isSelected(FontChoice.family(family)),
                          onTap: () => _pop(FontChoice.family(family)),
                        ),
                  ],
                ),
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// 字体选项行：字体名用其自身字体渲染，便于直接预览效果。
class _FontOptionTile extends StatelessWidget {
  const _FontOptionTile({
    required this.label,
    this.family,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String? family;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    // 预览：系统字体族名可直接被引擎解析；缺失时按默认字体渲染。
                    fontFamily: family,
                    color: selected ? scheme.primary : scheme.onSurface,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (selected)
                Icon(Icons.check_rounded, color: scheme.primary, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
