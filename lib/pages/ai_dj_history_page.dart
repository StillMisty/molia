/// AI 推荐历史页：批次索引列表 + 按需加载曲目 + 播放 / 加入队列 / 设为当前 /
/// 删除 / 清空历史。
///
/// 历史是只读记录：不在这里编辑反馈。功能关闭时仍可查看；「播放这批」按普通
/// 队列播放，不启动自动补歌（由 provider 决定）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/ai_dj.dart';
import '../l10n/app_localizations.dart';
import '../providers/ai_dj_provider.dart';
import '../providers/app_providers.dart';
import '../services/notification_service.dart';
import '../theme/m3e_context.dart';
import '../widgets/ai_dj_shared.dart';
import '../widgets/card_list_surface.dart';
import '../widgets/settings/settings_tiles.dart';

class AiDjHistoryPage extends ConsumerStatefulWidget {
  const AiDjHistoryPage({super.key});

  @override
  ConsumerState<AiDjHistoryPage> createState() => _AiDjHistoryPageState();
}

class _AiDjHistoryPageState extends ConsumerState<AiDjHistoryPage> {
  final Set<String> _expanded = {};
  final Set<String> _loading = {};
  final Set<String> _failed = {};
  final Map<String, AiDjBatch> _batches = {};

  /// 命令面：历史加载 / 播放 / 删除都落在这个控制器上；读状态走快照。
  AiDjProvider get _controller => ref.read(aiDjControllerProvider);

  Future<void> _toggle(String id) async {
    if (_expanded.contains(id)) {
      setState(() => _expanded.remove(id));
      return;
    }
    setState(() => _expanded.add(id));
    if (_batches.containsKey(id) || _loading.contains(id)) return;
    await _loadBatch(id);
  }

  /// 展开时的单批加载；失败只记这一批，重试也走这里（不触发重新生成）。
  Future<void> _loadBatch(String id) async {
    if (_loading.contains(id)) return;
    setState(() {
      _loading.add(id);
      _failed.remove(id);
      _batches.remove(id);
    });
    final batch = await _controller.loadHistoryBatch(id);
    if (!mounted) return;
    setState(() {
      _loading.remove(id);
      if (batch == null) {
        _failed.add(id);
      } else {
        _failed.remove(id);
        _batches[id] = batch;
      }
    });
  }

  /// 删除单批前先确认：历史页删除不可撤销，误触会丢整批记录。
  Future<void> _deleteBatch(AiDjHistoryEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    final navigator = Navigator.of(context, rootNavigator: true);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.aiDjHistoryDelete,
        content: Text(l10n.aiDjHistoryDeleteBody),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(false),
            child: Text(l10n.cancel),
          ),
          settingsDestructiveAction(
            context,
            key: Key('aiDjHistoryDeleteConfirm_${entry.id}'),
            onPressed: () => navigator.pop(true),
            label: l10n.delete,
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _controller.deleteHistoryBatch(entry.id);
    if (!mounted) return;
    setState(() {
      _expanded.remove(entry.id);
      _batches.remove(entry.id);
      _failed.remove(entry.id);
      _loading.remove(entry.id);
    });
  }

  Future<void> _clearHistory() async {
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
          settingsDestructiveAction(
            context,
            key: const Key('aiDjHistoryClearConfirm'),
            onPressed: () => navigator.pop(true),
            label: l10n.aiDjHistoryClear,
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _controller.clearHistory();
    if (!mounted) return;
    setState(() {
      _expanded.clear();
      _batches.clear();
    });
    _notify(l10n.aiDjHistoryCleared);
  }

  void _notify(String message) {
    final NotificationService? notifications = ref.read(
      notificationServiceProvider,
    );
    if (notifications == null) {
      M3ESnackbar.show(context, message: message);
    } else {
      notifications.showSuccessSnackBar(message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(aiDjProvider);
    final entries = state.historyEntries;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.aiDjHistoryTitle),
        automaticallyImplyLeading: true,
        actions: [
          if (entries.length > 1)
            M3EButton.text(
              key: const Key('aiDjHistoryClearButton'),
              onPressed: state.isBusy ? null : _clearHistory,
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
                itemBuilder: (context, index) =>
                    _entryCard(l10n, state, entries[index]),
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
            Text(l10n.aiDjHistoryEmpty, style: context.typeScale.titleMedium),
            const SizedBox(height: 4),
            Text(
              l10n.aiDjHistoryEmptyHint,
              textAlign: TextAlign.center,
              style: context.typeScale.bodySmall.copyWith(
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
    AiDjState state,
    AiDjHistoryEntry entry,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = state.isActiveBatch(entry.id);
    final expanded = _expanded.contains(entry.id);
    final batch = _batches[entry.id];
    final actions = <M3EButtonGroupAction>[
      M3EButtonGroupAction(
        icon: const Icon(Icons.play_arrow_rounded),
        label: Text(l10n.aiDjHistoryPlay),
        enabled: !state.queueBusy,
      ),
      M3EButtonGroupAction(
        icon: const Icon(Icons.playlist_add_rounded),
        label: Text(l10n.aiDjHistoryEnqueue),
        enabled: !state.queueBusy,
      ),
      if (!active)
        M3EButtonGroupAction(
          icon: const Icon(Icons.check_circle_rounded),
          label: Text(l10n.aiDjHistorySetActive),
          enabled: !state.isBusy,
        ),
    ];
    final handlers = <VoidCallback>[
      () => unawaited(_controller.playHistoryBatch(entry.id)),
      () => unawaited(_controller.enqueueHistoryBatch(entry.id)),
      if (!active) () => unawaited(_controller.setActiveBatch(entry.id)),
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
                  style: context.typeScale.titleSmall,
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
              l10n.aiDjHistorySource(aiDjOriginText(l10n, entry.origin)),
            ].join(' · '),
            style: context.typeScale.bodySmall.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (entry.preferences != null) ...[
            const SizedBox(height: 4),
            Text(
              aiDjPreferencesSummary(l10n, entry.preferences!),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.typeScale.labelSmall.copyWith(
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
                onPressed: state.isBusy
                    ? null
                    : () => unawaited(_deleteBatch(entry)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: M3EButton.text(
              key: Key('aiDjHistoryExpand_${entry.id}'),
              onPressed: () => unawaited(_toggle(entry.id)),
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
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.aiDjHistoryLoadFailed,
                      style: context.typeScale.bodySmall.copyWith(
                        color: scheme.error,
                      ),
                    ),
                  ),
                  M3EButton.text(
                    key: Key('aiDjHistoryRetry_${entry.id}'),
                    onPressed: state.isBusy
                        ? null
                        : () => unawaited(_loadBatch(entry.id)),
                    child: Text(l10n.retry),
                  ),
                ],
              )
            else if (batch != null)
              for (final (index, item) in batch.items.indexed)
                M3ETappable(
                  onTap: state.queueBusy
                      ? null
                      : () => unawaited(
                          _controller.playHistoryBatch(
                            entry.id,
                            startIndex: index,
                          ),
                        ),
                  enabled: !state.queueBusy,
                  mouseCursor: SystemMouseCursors.click,
                  semanticButton: true,
                  builder:
                      (BuildContext context, M3EInteractionState interaction) =>
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.track.title,
                                  style: context.typeScale.bodyMedium,
                                ),
                                Text(
                                  [
                                    if (item.track.artistLabel.isNotEmpty)
                                      item.track.artistLabel,
                                  ].join(' · '),
                                  style: context.typeScale.bodySmall.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                                if (item.source.reason.isNotEmpty)
                                  Text(
                                    item.source.reason,
                                    style: context.typeScale.labelSmall
                                        .copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                  ),
                              ],
                            ),
                          ),
                ),
          ],
        ],
      ),
    );
  }
}
