/// 发现页 AI 推歌推荐流：搜索框下方的 carousel。
///
/// - 展示待播批次（`AiDjProvider.pendingBatch`）：封面卡 + 歌名/歌手/理由；
///   点卡即从该首起播、AI 接管队列（`playFromPending`）；
/// - 尾部「换一批」卡替换待播批次（推歌中只换"下一批"，不打断播放）；
/// - **仅模式生效时出现（preparing / playing）**：关闭状态下发现页完全不显示
///   （入口在设置 › 内容 › AI 推歌 与播放页徽标）；
/// - 生成中 → 骨架卡；生成失败且无可用批次 → 重试卡；
/// - 搜索激活时由调用方（搜索 tab）隐藏整条；
/// - 未注册 AI provider 的上下文（精简壳 / 测试）安全隐藏。
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

  /// carousel 高度：封面 + 歌名/歌手/理由三行。
  static const double _carouselHeight = 198;

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AiDjProvider?>();
    if (provider == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: provider,
      builder: (context, _) {
        if (!provider.isActive) return const SizedBox.shrink();
        // 帧后校验/生成待播批次（build 期间不改 provider 状态）。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(provider.ensurePendingBatch());
        });
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
                          l10n.aiDjTitle,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _statusText(l10n, provider),
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
                  TextButton(
                    key: const Key('aiDjManageButton'),
                    onPressed: () => _openPage(context),
                    child: Text(l10n.aiDjManage),
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

  String _statusText(AppLocalizations l10n, AiDjProvider provider) {
    if (provider.status == AiDjStatus.playing) {
      return '${l10n.aiDjStatusPlaying} · ${l10n.aiDjQueued(provider.queuedCount)}';
    }
    if (provider.status == AiDjStatus.preparing ||
        (provider.isBusy && !provider.hasPendingBatch)) {
      return l10n.aiDjGenerating;
    }
    return l10n.aiDjDiscoverSubtitle;
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    AiDjProvider provider,
  ) {
    final batch = provider.pendingBatch;
    if (batch == null || batch.items.isEmpty) {
      final error = provider.lastError;
      if (error != null && !provider.isBusy) {
        return _guideCard(
          context,
          key: const Key('aiDjBatchErrorCard'),
          icon: Icons.error_outline_rounded,
          title: l10n.aiDjBatchFailed,
          subtitle: aiDjFailureText(l10n, error),
          trailingIcon: Icons.refresh_rounded,
          onTap: () => unawaited(provider.refreshPendingBatch()),
        );
      }
      return _skeleton(context);
    }
    return _carousel(context, l10n, provider, batch);
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
    return M3ECarousel(
      key: const Key('aiDjCarousel'),
      type: M3ECarouselType.contained,
      height: _carouselHeight,
      children: [
        for (var i = 0; i < batch.items.length; i++)
          M3ECarouselItem(
            image: _songCard(context, batch.items[i]),
            semanticLabel: _semanticLabel(batch.items[i]),
            onTap: () => unawaited(provider.playFromPending(i)),
          ),
        M3ECarouselItem(
          image: _refreshCard(context, l10n),
          semanticLabel: l10n.aiDjRefreshBatch,
          onTap: () => unawaited(provider.refreshPendingBatch()),
        ),
      ],
    );
  }

  String _semanticLabel(ResolvedRecommendation item) {
    final artist = item.track.artists.map((a) => a.name).join(', ');
    return artist.isEmpty ? item.track.title : '${item.track.title} - $artist';
  }

  Widget _songCard(BuildContext context, ResolvedRecommendation item) {
    final scheme = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    final artist = item.track.artists.map((a) => a.name).join(', ');
    final reason = item.source.reason;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SizedBox(
            width: double.infinity,
            child: AppNetworkImage(
              url: item.track.artwork?.uri.toString(),
              fit: BoxFit.cover,
              borderRadius: BorderRadius.circular(14),
              fallbackColor: scheme.surfaceContainerHighest,
              fallbackIconSize: 32,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          item.track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: type.titleSmall,
        ),
        if (artist.isNotEmpty)
          Text(
            artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: type.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        if (reason.isNotEmpty)
          Text(
            reason,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: type.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
      ],
    );
  }

  Widget _refreshCard(BuildContext context, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(
              child: Icon(
                Icons.refresh_rounded,
                size: 34,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.aiDjRefreshBatch,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ],
    );
  }

  void _openPage(BuildContext context) {
    ResponsiveNavigation.showAdaptiveModalPage(
      context: context,
      child: const AiDjPage(),
    );
  }
}
