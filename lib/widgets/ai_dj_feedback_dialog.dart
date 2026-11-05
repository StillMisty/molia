/// 反馈与记忆弹窗：本轮反馈 + 长期记忆 + 「多来点这种」。
///
/// 内容收进弹窗而不是铺在 AI 页：反馈会随使用越来越多，平铺会把页面拉成
/// 长列表；入口行只保留条数摘要，具体条目在这里查看和撤销。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../providers/ai_dj_provider.dart';
import '../theme/m3e_context.dart';
import 'ai_dj_shared.dart';

/// 打开「反馈与记忆」弹窗。
///
/// [onClearMemory] 由页面提供（确认弹窗与提示沿用页面已有流程）。
Future<void> showAiDjFeedbackDialog(
  BuildContext context,
  AiDjProvider provider, {
  required Future<void> Function() onClearMemory,
}) {
  return M3EDialog.show<void>(
    context,
    dialog: _AiDjFeedbackDialog(
      provider: provider,
      onClearMemory: onClearMemory,
    ),
  );
}

class _AiDjFeedbackDialog extends StatelessWidget {
  const _AiDjFeedbackDialog({
    required this.provider,
    required this.onClearMemory,
  });

  final AiDjProvider provider;
  final Future<void> Function() onClearMemory;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final maxHeight = (MediaQuery.sizeOf(context).height * 0.45).clamp(
      220.0,
      460.0,
    );

    // 撤销「不感兴趣」、移除种子、清空记忆都会 notify：弹窗内容跟着刷新，
    // 不需要调用方手动 setState。
    return ListenableBuilder(
      listenable: provider,
      builder: (context, _) {
        final round = aiDjRoundFeedback(provider);
        final rememberedSkipped = provider.rememberedSkippedLabels;
        final rememberedLiked = provider.rememberedLikedLabels;
        final seeds = provider.seeds;
        final hasRound =
            round.notInterested.isNotEmpty ||
            round.skipped.isNotEmpty ||
            round.liked.isNotEmpty;
        final hasMemory =
            rememberedSkipped.isNotEmpty || rememberedLiked.isNotEmpty;
        final hasSeeds = seeds.isNotEmpty;
        final hasAny = hasRound || hasMemory || hasSeeds;

        return M3EDialog(
          key: const Key('aiDjFeedbackDialog'),
          title: l10n.aiDjFeedbackTitle,
          content: SizedBox(
            width: 520,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: hasAny
                  ? SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (hasRound)
                            _chipSection(context, l10n.aiDjFeedbackThisRound, [
                              for (final item in round.notInterested)
                                M3EChip(
                                  key: Key(
                                    'aiDjNotInterested_${item.track.id.uri}',
                                  ),
                                  type: M3EChipType.input,
                                  label:
                                      '${l10n.aiDjNotInterested} · '
                                      '${item.source.label}',
                                  onDeleted: () => unawaited(
                                    provider.undoNotInterested(
                                      item.track.id.uri,
                                    ),
                                  ),
                                  onPressed: () => unawaited(
                                    provider.undoNotInterested(
                                      item.track.id.uri,
                                    ),
                                  ),
                                ),
                              for (final label in round.skipped.take(10))
                                M3EChip(
                                  type: M3EChipType.assist,
                                  label:
                                      '${l10n.aiDjFeedbackSkipped} · '
                                      '$label',
                                ),
                              for (final label in round.liked.take(10))
                                M3EChip(
                                  type: M3EChipType.assist,
                                  label: '${l10n.aiDjFeedbackLiked} · $label',
                                ),
                            ]),
                          if (hasMemory) ...[
                            if (hasRound) const SizedBox(height: 16),
                            _chipSection(context, l10n.aiDjFeedbackMemory, [
                              for (final label in rememberedSkipped.take(10))
                                M3EChip(
                                  type: M3EChipType.assist,
                                  label:
                                      '${l10n.aiDjFeedbackSkipped} · '
                                      '$label',
                                ),
                              for (final label in rememberedLiked.take(10))
                                M3EChip(
                                  type: M3EChipType.assist,
                                  label: '${l10n.aiDjFeedbackLiked} · $label',
                                ),
                            ]),
                          ],
                          if (hasSeeds) ...[
                            if (hasRound || hasMemory)
                              const SizedBox(height: 16),
                            _chipSection(context, l10n.aiDjSeedsTitle, [
                              for (final seed in seeds)
                                M3EChip(
                                  key: Key('aiDjSeed_$seed'),
                                  type: M3EChipType.input,
                                  label: l10n.aiDjSeedLabel(seed),
                                  onDeleted: () =>
                                      unawaited(provider.removeSeed(seed)),
                                ),
                            ]),
                            const SizedBox(height: 4),
                            Text(
                              l10n.aiDjSeedsHint,
                              style: context.typeScale.bodySmall.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    )
                  : Text(
                      l10n.aiDjFeedbackEmpty,
                      style: context.typeScale.bodyMedium.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
            ),
          ),
          actions: [
            if (hasAny)
              M3EButton.text(
                key: const Key('aiDjClearMemoryButton'),
                onPressed: () => unawaited(onClearMemory()),
                child: Text(l10n.aiDjClearMemory),
              ),
            M3EButton.text(
              key: const Key('aiDjFeedbackCloseButton'),
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              child: Text(l10n.close),
            ),
          ],
        );
      },
    );
  }

  Widget _chipSection(BuildContext context, String title, List<Widget> chips) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: context.typeScale.labelMedium),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: chips),
      ],
    );
  }
}
