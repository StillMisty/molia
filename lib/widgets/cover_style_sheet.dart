/// 封面风格选择弹层：应用范围分段 + 风格预览网格。
///
/// 预览用当前曲目的真实封面（没有则默认封面；都没有显示占位与提示），
/// 所有预览按 256px 派生图展示；点击立即写设置并轻反馈，弹层保持打开。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/cover_style.dart';
import '../l10n/app_localizations.dart';
import '../providers/playback_provider.dart';
import '../services/covers/cover_style_cache.dart';
import '../services/covers/cover_style_settings.dart';
import '../services/haptics.dart';
import '../theme/m3e_context.dart';
import 'cover_style_labels.dart';
import 'molia_mark.dart';
import 'styled_cover_image.dart';
import 'track_artwork.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 打开封面风格弹层。
///
/// Provider 缺失（独立挂载 / 旧测试）时不打开、不报错。
Future<void> showCoverStyleSheet(BuildContext context) {
  final settings = context.read<CoverStyleSettings?>();
  if (settings == null) return Future.value();
  final covers = coverResolverOf(context);
  final track = context.read<PlaybackProvider?>()?.snapshot.current;
  final previewUrl = covers.realOf(track).url ?? covers.defaultCoverUrl;
  return M3EBottomSheet.show<void>(
    context,
    // 直接展开到内容高度（上限为屏幕可用高度）：9 个风格卡片在收起态
    // 只露出半屏，底部的「完成」会落在屏幕外。
    initialValue: M3EBottomSheetValue.expanded,
    builder: (_) => CoverStyleSheet(
      settings: settings,
      cache: context.read<CoverStyleCache?>(),
      previewUrl: previewUrl,
    ),
  );
}

/// 弹层内容（公开便于独立测试）。
class CoverStyleSheet extends StatelessWidget {
  const CoverStyleSheet({
    super.key,
    required this.settings,
    this.cache,
    this.previewUrl,
  });

  final CoverStyleSettings settings;
  final CoverStyleCache? cache;

  /// 当前曲目真实封面 / 默认封面；null = 没有任何可预览封面。
  final String? previewUrl;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final scheme = Theme.of(context).colorScheme;
    final url = previewUrl;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 4),
            child: Text(
              l10n.coverStyleTitle,
              style: context.typeScale.titleMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              l10n.coverStyleSheetSubtitle,
              style: context.typeScale.bodyMedium.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: AnimatedBuilder(
                animation: settings,
                builder: (context, _) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l10n.coverStyleScopeTitle,
                        style: context.typeScale.titleSmall.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: M3ESegmentedButton<CoverStyleScope>(
                          key: const Key('coverStyleScopeControl'),
                          segments: [
                            M3ESegment(
                              value: CoverStyleScope.player,
                              label: l10n.coverStyleScopePlayer,
                            ),
                            M3ESegment(
                              value: CoverStyleScope.all,
                              label: l10n.coverStyleScopeAll,
                            ),
                          ],
                          selected: {settings.scope},
                          onSelectionChanged: (selection) {
                            if (selection.isEmpty) return;
                            HapticsService.selectionClick();
                            unawaited(settings.setScope(selection.first));
                          },
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        coverStyleScopeDescription(l10n, settings.scope),
                        style: context.typeScale.bodySmall.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      if (url == null) ...[
                        const SizedBox(height: 10),
                        Text(
                          l10n.coverStyleNoPreview,
                          key: const Key('coverStyleNoPreview'),
                          style: context.typeScale.bodySmall.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final crossAxisCount = constraints.maxWidth >= 520
                              ? 3
                              : 2;
                          return GridView.builder(
                            key: const Key('coverStyleGrid'),
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: CoverStyle.values.length,
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: crossAxisCount,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                  mainAxisExtent: 188,
                                ),
                            itemBuilder: (context, index) {
                              final style = CoverStyle.values[index];
                              return _CoverStyleCard(
                                style: style,
                                selected: settings.style == style,
                                previewUrl: url,
                                cache: cache,
                                onTap: () {
                                  HapticsService.selectionClick();
                                  unawaited(settings.setStyle(style));
                                },
                              );
                            },
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: M3EButton.filled(
              key: const Key('coverStyleDone'),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.coverStyleDone),
            ),
          ),
        ],
      ),
    );
  }
}

class _CoverStyleCard extends StatelessWidget {
  const _CoverStyleCard({
    required this.style,
    required this.selected,
    required this.previewUrl,
    required this.cache,
    required this.onTap,
  });

  final CoverStyle style;
  final bool selected;
  final String? previewUrl;
  final CoverStyleCache? cache;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final scheme = Theme.of(context).colorScheme;
    final preview = previewUrl;
    return M3ECard(
      key: Key('coverStyleCard_${style.id}'),
      variant: M3ECardVariant.filled,
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      border: selected
          ? BorderSide(color: scheme.primary, width: 2)
          : BorderSide(color: scheme.outlineVariant),
      padding: const EdgeInsets.all(8),
      onPressed: onTap,
      semanticLabel:
          '${coverStyleName(l10n, style)}, '
          '${coverStyleDescription(l10n, style)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 96,
            child: Center(
              child: preview == null
                  ? Container(
                      width: 96,
                      height: 96,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: MoliaMark(
                        size: 28,
                        color: scheme.onSurfaceVariant,
                      ),
                    )
                  : StyledCoverImage(
                      url: preview,
                      style: style,
                      width: 96,
                      height: 96,
                      edge: 256,
                      cache: cache,
                      borderRadius: BorderRadius.circular(12),
                      memCacheWidth: 256,
                      fallbackIconSize: 28,
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  coverStyleName(l10n, style),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.typeScale.bodyLarge.copyWith(
                    color: selected
                        ? scheme.onPrimaryContainer
                        : scheme.onSurface,
                  ),
                ),
              ),
              if (selected)
                Icon(
                  Icons.check_circle_rounded,
                  size: 18,
                  color: scheme.primary,
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            coverStyleDescription(l10n, style),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.typeScale.bodySmall.copyWith(
              color: selected
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
