/// 搜索辅助的唯一呈现模块：最近搜索 / 热搜 chips + 输入建议列表。
///
/// 两个宿主（桌面 Ctrl+F 遮罩与资料库搜索 tab）只传各自的版式差异；可见性
/// （聚焦、空词、首屏是否已返回）由 [SearchAssistController] 判定。面板最多
/// 6 条，没有任何内容时完全不占位。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../domain/search/search_assist.dart';
import '../providers/search_assist_controller.dart';
import '../services/notification_service.dart';
import '../theme/m3e_context.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 面板在两种宿主里的版式差异。
enum SearchAssistVariant {
  /// 桌面遮罩：与结果面板同一块圆角容器，紧贴搜索条下缘。
  docked,

  /// 资料库搜索 tab：搜索条下方的低强调块，不抢结果的视觉重心。
  page,
}

class SearchAssistPanel extends StatelessWidget {
  const SearchAssistPanel({
    super.key,
    required this.controller,
    this.variant = SearchAssistVariant.page,
  });

  final SearchAssistController controller;
  final SearchAssistVariant variant;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final value = controller.value;
        if (!value.isVisible) return const SizedBox.shrink();
        final content = value.showChips
            ? _chips(context, value)
            : _suggestions(context, value);
        if (variant == SearchAssistVariant.docked) {
          final m3e = M3ETheme.of(context);
          return DecoratedBox(
            decoration: BoxDecoration(
              color: m3e.searchViewTheme.containedContainerColor(
                m3e.colorScheme,
              ),
              borderRadius: M3EShapes.radiusExtraLarge,
            ),
            child: ClipRRect(
              borderRadius: M3EShapes.radiusExtraLarge,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: content,
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: M3ECard(
            variant: M3ECardVariant.filled,
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: content,
          ),
        );
      },
    );
  }

  Widget _chips(BuildContext context, SearchAssistViewModel value) {
    final l10n = _l10n(context);
    final scheme = Theme.of(context).colorScheme;
    final sections = <Widget>[];
    if (value.chips.recent.isNotEmpty) {
      sections.add(
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.searchRecentTitle,
                style: context.typeScale.labelLarge.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            M3EButton.text(
              onPressed: () {
                controller.clearHistory();
                context.read<NotificationService?>()?.showSuccessSnackBar(
                  l10n.searchRecentCleared,
                );
              },
              child: Text(l10n.searchRecentClear),
            ),
          ],
        ),
      );
      sections.add(const SizedBox(height: 8));
      sections.add(
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final query in value.chips.recent)
              Semantics(
                label: l10n.searchHistoryDelete(query),
                child: M3EChip(
                  label: query,
                  type: M3EChipType.input,
                  onPressed: () => controller.selectSuggestion(
                    SearchSuggestion(
                      text: query,
                      source: SearchSuggestionSource.history,
                    ),
                  ),
                  onDeleted: () => controller.deleteHistory(query),
                ),
              ),
          ],
        ),
      );
    }
    if (value.chips.hot.isNotEmpty) {
      if (sections.isNotEmpty) sections.add(const SizedBox(height: 12));
      sections.add(
        Text(
          l10n.discoverHotSearches,
          style: context.typeScale.labelLarge.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
      sections.add(const SizedBox(height: 8));
      sections.add(
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final query in value.chips.hot)
              M3EChip(
                label: query,
                type: M3EChipType.assist,
                onPressed: () => controller.selectSuggestion(
                  SearchSuggestion(
                    text: query,
                    source: SearchSuggestionSource.hot,
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: sections,
    );
  }

  Widget _suggestions(BuildContext context, SearchAssistViewModel value) {
    final l10n = _l10n(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: l10n.searchSuggestionsLabel,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < value.suggestions.length; index++)
            Padding(
              padding: EdgeInsets.only(top: index == 0 ? 0 : 6),
              child: Semantics(
                label: l10n.searchSuggestionAction(
                  value.suggestions[index].text,
                ),
                child: M3EListItem(
                  key: ValueKey(
                    'searchSuggestion:${value.suggestions[index].text}',
                  ),
                  headline: value.suggestions[index].text,
                  leading: Icon(
                    value.suggestions[index].source ==
                            SearchSuggestionSource.history
                        ? Icons.history_rounded
                        : Icons.local_fire_department_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  selected: index == value.highlightedIndex,
                  onTap: () =>
                      controller.selectSuggestion(value.suggestions[index]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
