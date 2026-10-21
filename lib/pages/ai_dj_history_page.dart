/// AI 推荐历史页：批次索引列表 + 按需加载曲目 + 播放 / 加入队列 / 设为当前 /
/// 删除 / 清空历史。
///
/// 历史是只读记录：不在这里编辑反馈。功能关闭时仍可查看；「播放这批」按普通
/// 队列播放，不启动自动补歌（由 provider 决定）。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/ai_dj.dart';
import '../l10n/app_localizations.dart';
import '../providers/ai_dj_provider.dart';
import '../services/notification_service.dart';
import '../widgets/ai_dj_shared.dart';
import '../widgets/card_list_surface.dart';

class AiDjHistoryPage extends StatefulWidget {
  const AiDjHistoryPage({super.key});

  @override
  State<AiDjHistoryPage> createState() => _AiDjHistoryPageState();
}

class _AiDjHistoryPageState extends State<AiDjHistoryPage> {
  final Set<String> _expanded = {};
  final Set<String> _loading = {};
  final Set<String> _failed = {};
  final Map<String, AiDjBatch> _batches = {};

  Future<void> _toggle(String id, AiDjProvider provider) async {
    if (_expanded.contains(id)) {
      setState(() => _expanded.remove(id));
      return;
    }
    setState(() => _expanded.add(id));
    if (_batches.containsKey(id) || _loading.contains(id)) return;
    setState(() => _loading.add(id));
    final batch = await provider.loadHistoryBatch(id);
    if (!mounted) return;
    setState(() {
      _loading.remove(id);
      if (batch == null) {
        _failed.add(id);
      } else {
        _batches[id] = batch;
      }
    });
  }

  Future<void> _clearHistory(AiDjProvider provider) async {
    final l10n = AppLocalizations.of(context)!;
    final navigator = Navigator.of(context, rootNavigator: true);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.aiDjHistoryClearTitle,
        content: Text(l10n.aiDjHistoryClearBody),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            key: const Key('aiDjHistoryClearConfirm'),
            onPressed: () => navigator.pop(true),
            child: Text(l10n.aiDjHistoryClear),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await provider.clearHistory();
    if (!mounted) return;
    setState(() {
      _expanded.clear();
      _batches.clear();
    });
    _notify(l10n.aiDjHistoryCleared);
  }

  void _notify(String message) {
    final notifications = context.read<NotificationService?>();
    if (notifications == null) {
      M3ESnackbar.show(context, message: message);
    } else {
      notifications.showSuccessSnackBar(message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<AiDjProvider>();
    final entries = provider.historyEntries;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.aiDjHistoryTitle),
        automaticallyImplyLeading: true,
        actions: [
          if (entries.length > 1)
            M3EButton.text(
              key: const Key('aiDjHistoryClearButton'),
              onPressed: provider.isBusy ? null : () => _clearHistory(provider),
              child: Text(l10n.aiDjHistoryClear),
            ),
        ],
      ),
      body: SafeArea(
        child: entries.isEmpty
            ? _empty(l10n)
            : ListView.separated(
                key: const Key('aiDjHistoryList'),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                itemCount: entries.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 10),
                itemBuilder: (context, index) => _entryCard(
                  l10n,
                  provider,
                  entries[index],
                ),
              ),
      ),
    );
  }

  Widget _empty(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history_rounded,
              size: 40,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(l10n.aiDjHistoryEmpty, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              l10n.aiDjHistoryEmptyHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entryCard(
    AppLocalizations l10n,
    AiDjProvider provider,
    AiDjHistoryEntry entry,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = provider.isActiveBatch(entry.id);
    final expanded = _expanded.contains(entry.id);
    final batch = _batches[entry.id];
    final actions = <M3EButtonGroupAction>[
      M3EButtonGroupAction(
        icon: const Icon(Icons.play_arrow_rounded),
        label: Text(l10n.aiDjHistoryPlay),
        enabled: !provider.isBusy,
      ),
      M3EButtonGroupAction(
        icon: const Icon(Icons.playlist_add_rounded),
        label: Text(l10n.aiDjHistoryEnqueue),
        enabled: !provider.isBusy,
      ),
      if (!active)
        M3EButtonGroupAction(
          icon: const Icon(Icons.check_circle_rounded),
          label: Text(l10n.aiDjHistorySetActive),
          enabled: !provider.isBusy,
        ),
    ];
    final handlers = <VoidCallback>[
      () => unawaited(provider.playHistoryBatch(entry.id)),
      () => unawaited(provider.enqueueHistoryBatch(entry.id)),
      if (!active) () => unawaited(provider.setActiveBatch(entry.id)),
    ];
    return CardListSurface(
      key: Key('aiDjHistoryEntry_${entry.id}'),
      position: M3ECardPosition.single,
      color: scheme.surfaceContainerHigh,
      onPressed: null,
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  aiDjUpdatedText(l10n, entry.generatedAt),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (active)
                M3EChip(
                  type: M3EChipType.assist,
                  label: l10n.aiDjHistoryActive,
                  selected: true,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              l10n.aiDjHistoryItems(entry.itemCount),
              if (entry.unresolvedCount > 0)
                l10n.aiDjHistoryUnresolved(entry.unresolvedCount),
              l10n.aiDjHistorySource(
                aiDjOriginText(l10n, entry.origin),
              ),
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (entry.preferences != null) ...[
            const SizedBox(height: 4),
            Text(
              aiDjPreferencesSummary(l10n, entry.preferences!),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: M3EButtonGroup(
                    key: Key('aiDjHistoryActions_${entry.id}'),
                    type: M3EButtonGroupType.standard,
                    style: M3EButtonStyle.tonal,
                    // 窄屏放不下时收进菜单，尾部动作仍可达。
                    overflow: M3EButtonGroupOverflow.menu,
                    overflowIcon: const Icon(Icons.more_horiz_rounded),
                    actions: actions,
                    // 命令式动作：按下即分发，不保留选中态。
                    selectedIndex: null,
                    onSelectedIndexChanged: (index) {
                      if (index != null) handlers[index]();
                    },
                  ),
                ),
              ),
              const SizedBox(width: 4),
              M3EIconButton(
                key: Key('aiDjHistoryDelete_${entry.id}'),
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(Icons.delete_rounded),
                semanticLabel: l10n.aiDjHistoryDelete,
                onPressed: provider.isBusy
                    ? null
                    : () => unawaited(provider.deleteHistoryBatch(entry.id)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: M3EButton.text(
              key: Key('aiDjHistoryExpand_${entry.id}'),
              onPressed: () => unawaited(_toggle(entry.id, provider)),
              child: Text(
                expanded ? l10n.aiDjHistoryCollapse : l10n.aiDjHistoryExpand,
              ),
            ),
          ),
          if (expanded) ...[
            const SizedBox(height: 8),
            if (_loading.contains(entry.id))
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: M3ELoadingIndicator()),
              )
            else if (_failed.contains(entry.id))
              Text(
                l10n.aiDjHistoryLoadFailed,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              )
            else if (batch != null)
              for (final item in batch.items) ...[
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: provider.isBusy
                      ? null
                      : () => unawaited(provider.playHistoryBatch(entry.id)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.track.title,
                            style: theme.textTheme.bodyMedium),
                        Text(
                          [
                            if (item.track.artistLabel.isNotEmpty)
                              item.track.artistLabel,
                            item.resolvedSourceName,
                          ].join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (item.source.reason.isNotEmpty)
                          Text(
                            item.source.reason,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
          ],
        ],
      ),
    );
  }
}
