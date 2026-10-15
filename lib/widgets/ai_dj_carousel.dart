/// 发现页「今日推荐」区：搜索框下方的推荐流。
///
/// - 展示 [AiDjProvider.recommendations]（持久化的今日推荐列表）：封面卡 +
///   歌名/歌手（用 carousel 原生槽位，保证每张卡都常显，不再把文字塞进
///   图片层被槽位裁掉）；
/// - 点卡即从该首起播、AI 接管队列（`playRecommendation`）；
/// - 尾部「换一批」卡替换列表（推歌中只换"下一批来源"，不打断播放）；
/// - 只在功能启用时出现（未配置/未启用 → 发现页完全不显示）；
/// - 列表为空 → 显式「生成推荐」引导卡；生成中 → 骨架；失败 → 重试卡；
/// - 过期不做提示（「上次更新」只在卡片区副标题展示）。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/ai_dj.dart';
import '../l10n/app_localizations.dart';
import '../pages/ai_dj_page.dart';
import '../providers/ai_dj_provider.dart';
import '../utils/responsive.dart';
import 'ai_dj_shared.dart';
import 'app_network_image.dart';

class AiDjCarousel extends StatefulWidget {
  const AiDjCarousel({super.key});

  @override
  State<AiDjCarousel> createState() => _AiDjCarouselState();
}

class _AiDjCarouselState extends State<AiDjCarousel> {
  /// 骨架卡/占位卡宽度（真实卡片宽度由 M3ECarousel 布局决定）。
  static const double _placeholderWidth = 132;

  /// carousel 高度：封面 + 槽位文字（文字由 carousel 叠在封面上）。
  static const double _carouselHeight = 198;

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AiDjProvider?>();
    if (provider == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: provider,
      builder: (context, _) {
        // 默认关闭：未启用时发现页完全不出现 AI 相关内容（不额外做引导）。
        if (!provider.enabled) return const SizedBox.shrink();
        final l10n = AppLocalizations.of(context)!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.aiDjTodayTitle,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _subtitleText(l10n, provider),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                      ],
                    ),
                  ),
                  M3EButton.text(
                    key: const Key('aiDjManageButton'),
                    onPressed: () => _openPage(context),
                    child: Text(l10n.aiDjViewAll),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _body(context, l10n, provider),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  String _subtitleText(AppLocalizations l10n, AiDjProvider provider) {
    final list = provider.recommendations;
    final parts = <String>[
      if (provider.status == AiDjStatus.playing) l10n.aiDjStatusPlaying,
      if (list != null)
        l10n.aiDjLastUpdated(aiDjUpdatedText(l10n, list.generatedAt)),
    ];
    if (parts.isEmpty) return l10n.aiDjDiscoverSubtitle;
    return parts.join(' · ');
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    AiDjProvider provider,
  ) {
    final list = provider.recommendations;
    if (list == null || list.items.isEmpty) {
      if (provider.isBusy) return _skeleton(context);
      final error = provider.lastError;
      if (error != null) {
        return _guideCard(
          context,
          key: const Key('aiDjBatchErrorCard'),
          icon: Icons.error_outline_rounded,
          title: l10n.aiDjBatchFailed,
          subtitle: aiDjFailureText(l10n, error),
          trailingIcon: Icons.refresh_rounded,
          onTap: () => unawaited(provider.refreshRecommendations()),
        );
      }
      // 空列表：显式生成（不自动消耗 token）。
      return _guideCard(
        context,
        key: const Key('aiDjGenerateCard'),
        icon: Icons.auto_awesome_rounded,
        title: l10n.aiDjEmptyList,
        subtitle: l10n.aiDjEmptyListHint,
        onTap: () => unawaited(provider.refreshRecommendations()),
      );
    }
    return _carousel(context, l10n, provider, list);
  }

  Widget _guideCard(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    IconData trailingIcon = Icons.chevron_right_rounded,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: M3ECard(
        key: key,
        variant: M3ECardVariant.filled,
        color: scheme.surfaceContainerHigh,
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        onPressed: onTap,
        child: Row(
          children: [
            Icon(icon, size: 22, color: scheme.tertiary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            Icon(trailingIcon, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _skeleton(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget box() => Container(
          width: _placeholderWidth,
          height: _placeholderWidth,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
          ),
        );
    return SizedBox(
      height: _placeholderWidth,
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          box(),
          const SizedBox(width: 10),
          box(),
          const SizedBox(width: 10),
          box(),
          const SizedBox(width: 10),
          box(),
        ],
      ),
    );
  }

  Widget _carousel(
    BuildContext context,
    AppLocalizations l10n,
    AiDjProvider provider,
    AiDjBatch batch,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    return M3ECarousel(
      key: const Key('aiDjCarousel'),
      type: M3ECarouselType.contained,
      height: _carouselHeight,
      children: [
        for (var i = 0; i < batch.items.length; i++)
          M3ECarouselItem(
            // 封面 + 原生 title/subtitle 槽位：文字由 carousel 按当前槽位
            // 渲染，任何宽度下都保留歌名与歌手。
            image: AppNetworkImage(
              url: batch.items[i].track.artwork?.uri.toString(),
              fit: BoxFit.cover,
              fallbackColor: scheme.surfaceContainerHighest,
              fallbackIconSize: 32,
            ),
            title: Text(
              batch.items[i].track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: type.titleSmall,
            ),
            subtitle: _artistOf(batch.items[i]).isEmpty
                ? null
                : Text(
                    _artistOf(batch.items[i]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.bodySmall,
                  ),
            // 关闭按槽位隐藏标题：歌名与歌手每张卡都要在。
            applyDynamicTextContentTransform: false,
            showScrim: const M3ECarouselScrim.gradient(),
            semanticLabel: _semanticLabel(batch.items[i]),
            onTap: () => unawaited(provider.playRecommendation(i)),
          ),
        M3ECarouselItem(
          image: Container(
            color: scheme.surfaceContainerHigh,
            child: Center(
              child: Icon(
                Icons.refresh_rounded,
                size: 34,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          title: Text(l10n.aiDjRefreshBatch, style: type.titleSmall),
          applyDynamicTextContentTransform: false,
          semanticLabel: l10n.aiDjRefreshBatch,
          onTap: () => unawaited(provider.refreshRecommendations()),
        ),
      ],
    );
  }

  static String _artistOf(ResolvedRecommendation item) => item.track.artists
      .map((artist) => artist.name)
      .where((name) => name.isNotEmpty)
      .join(', ');

  String _semanticLabel(ResolvedRecommendation item) {
    final artist = _artistOf(item);
    return artist.isEmpty ? item.track.title : '${item.track.title} - $artist';
  }

  void _openPage(BuildContext context) {
    ResponsiveNavigation.showAdaptiveModalPage(
      context: context,
      child: const AiDjPage(),
    );
  }
}
