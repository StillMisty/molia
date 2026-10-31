/// 搜索来源 chips：页面版与桌面遮罩共用的唯一实现。
///
/// 顺序严格由调用方传入（来自 `SearchProvider.sourceFilterOptions`，即
/// `SourceRegistry.descriptors` 的渠道管理顺序）；「全部」固定第一。
library;

import 'package:material_ui/material_ui.dart';

import '../domain/models/source.dart';
import '../l10n/app_localizations.dart';
import 'source_filter_chips.dart';

/// AppLocalizations 查找：测试等场景可能未注册 delegate，回退简体中文。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

class SearchSourceChips extends StatelessWidget {
  const SearchSourceChips({
    super.key,
    required this.options,
    required this.selectedKey,
    required this.onSelected,
  });

  final List<SourceDescriptor> options;
  final String selectedKey;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return SourceFilterChips(
      options: [
        for (final option in options)
          SourceFilterOption(key: option.key, label: option.displayName),
      ],
      selectedKey: selectedKey,
      onSelected: onSelected,
      groupLabel: l10n.searchSourcesLabel,
      allLabel: l10n.searchAllSources,
      chipKeyPrefix: 'searchSourceChip',
      scrollKey: const Key('searchSourceChipsScroll'),
    );
  }
}
