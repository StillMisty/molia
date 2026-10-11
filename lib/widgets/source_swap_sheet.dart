import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/playback_provider.dart';
import '../providers/source_swap_provider.dart';
import 'track_row.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本组件而不注册 delegate，
/// 此时回退到简体中文（与收藏页 / 加入列表弹层同一约定）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 打开换源弹层：跨音源搜索 → 试听 → 确认原位替换。
///
/// 位置由参数决定：`historyKey` → 播放历史原位替换；`playlistId` →
/// 收藏/自建列表原位替换；都为 null → 仅替换播放队列（播放页入口）。
Future<void> showSourceSwapSheet(
  BuildContext context, {
  required Track seed,
  int? playlistId,
  TrackKey? historyKey,
}) {
  final request = SourceSwapRequest(
    seed: seed,
    placement: historyKey != null
        ? SourceSwapPlacement.history
        : playlistId != null
            ? SourceSwapPlacement.playlist
            : SourceSwapPlacement.queue,
    playlistId: playlistId,
    historyKey: historyKey,
  );
  return M3EBottomSheet.show<void>(
    context,
    builder: (_) => SourceSwapSheet(request: request),
  );
}

/// 换源弹层内容：头部（原曲）→ 音源筛选 chip → 候选列表 → 底部确认。
@visibleForTesting
class SourceSwapSheet extends StatefulWidget {
  const SourceSwapSheet({super.key, required this.request});

  final SourceSwapRequest request;

  @override
  State<SourceSwapSheet> createState() => _SourceSwapSheetState();
}

class _SourceSwapSheetState extends State<SourceSwapSheet> {
  late final SourceSwapProvider _provider;

  /// 会话已发起（首帧微任务里 begin；发起前显示加载态，避免读到旧会话）。
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _provider = context.read<SourceSwapProvider>();
    // begin 会同步通知监听者；放到微任务里，避开本组件的首次 build。
    scheduleMicrotask(() {
      if (!mounted) return;
      setState(() => _started = true);
      _provider.begin(widget.request);
    });
  }

  @override
  void dispose() {
    // 关闭即结束会话：dispose 期间 widget 树处于锁定态，通知会触发
    // markNeedsBuild 断言；推迟到微任务清空，过期在途结果由会话 id 守卫丢弃。
    scheduleMicrotask(_provider.clear);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final provider = context.watch<SourceSwapProvider>();

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context, l10n, widget.request.seed),
          if (_started && provider.isSearching)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: M3EProgressIndicator.linear(),
            ),
          _buildBody(context, l10n, provider),
          _buildFooter(context, l10n, provider),
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    AppLocalizations l10n,
    Track seed,
  ) {
    final theme = Theme.of(context);
    final artist = seed.artists
        .map((artist) => artist.name)
        .where((name) => name.isNotEmpty)
        .join(', ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      child: Row(
        children: [
          Icon(
            Icons.swap_horiz_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.sourceSwap, style: theme.textTheme.titleMedium),
                Text(
                  artist.isEmpty ? seed.title : '${seed.title} · $artist',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    SourceSwapProvider provider,
  ) {
    if (!_started || (provider.isSearching && provider.groups.isEmpty)) {
      return const SizedBox(
        height: 140,
        child: Center(child: M3EProgressIndicator.circular()),
      );
    }
    if (provider.noOtherSources) {
      return _emptyState(Icons.source_rounded, l10n.sourceSwapNoSources);
    }
    if (provider.groups.isEmpty) {
      // 搜索已结束且无任何结果（失败源的重试入口在底部）。
      return _emptyState(Icons.search_off_rounded, l10n.sourceSwapEmpty);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSourceTabs(context, l10n, provider),
        Flexible(child: _buildCandidates(context, provider)),
      ],
    );
  }

  /// 音源筛选 chip（顺序即用户音源顺序）。
  Widget _buildSourceTabs(
    BuildContext context,
    AppLocalizations l10n,
    SourceSwapProvider provider,
  ) {
    return M3EChipGroup(
      groupLabel: l10n.sourceSwap,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: Row(
          children: [
            for (final group in provider.groups) ...[
              M3EChip(
                label: group.displayName,
                type: M3EChipType.filter,
                selected: group.sourceKey == provider.activeSourceKey,
                onPressed: () => provider.selectSource(group.sourceKey),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCandidates(
    BuildContext context,
    SourceSwapProvider provider,
  ) {
    final items = provider.activeItems;
    final gap = TrackRow.gapOf(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
        itemExtent: TrackRow.extent + gap,
        itemCount: items.length,
        itemBuilder: (context, index) {
          final track = items[index];
          return Padding(
            padding: EdgeInsets.only(bottom: gap),
            child: TrackRow(
              title: track.title,
              artist: track.artists
                  .map((artist) => artist.name)
                  .where((name) => name.isNotEmpty)
                  .join(', '),
              coverUrl: track.artwork?.uri.toString(),
              coverSize: 40,
              trailingText: _durationText(track.duration),
              position: calculateCardPosition(index, items.length),
              selected: provider.selected?.id == track.id,
              onTap: () => _selectAndPreview(track),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFooter(
    BuildContext context,
    AppLocalizations l10n,
    SourceSwapProvider provider,
  ) {
    final theme = Theme.of(context);
    final failed = provider.failedSourceKeys;
    final canApply = _started && provider.selected != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (failed.isNotEmpty && !provider.isSearching)
            Row(
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 18,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.sourceSwapFailedSources(failed.length),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                M3EButton.text(
                  onPressed: provider.retryFailed,
                  child: Text(l10n.retry),
                ),
              ],
            ),
          const SizedBox(height: 8),
          M3EButton.filled(
            onPressed: canApply ? _confirm : null,
            child: Text(l10n.sourceSwapConfirm),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(IconData icon, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 选中并立即试听：单曲上下文，试听会打断当前播放。
  void _selectAndPreview(Track track) {
    _provider.select(track);
    unawaited(
      context.read<PlaybackProvider>().playDomainTracks(
            [track],
            0,
            contextName: _l10n(context).sourceSwapPreviewContext,
          ),
    );
  }

  Future<void> _confirm() async {
    final l10n = _l10n(context);
    SourceSwapApplyResult result;
    try {
      result = await _provider.apply();
      if (result.status ==
          SourceSwapApplyStatus.duplicateConfirmationRequired) {
        if (!mounted) return;
        final confirmed = await M3EDialog.show<bool>(
          context,
          dialog: M3EDialog(
            title: l10n.sourceSwapDuplicateTitle,
            content: Text(l10n.sourceSwapDuplicateMessage),
            actions: [
              M3EButton.text(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.cancel),
              ),
              M3EButton.filled(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.sourceSwapConfirm),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        result = await _provider.apply(removeDuplicate: true);
      }
    } catch (_) {
      if (!mounted) return;
      M3ESnackbar.show(context, message: l10n.sourceSwapApplyFailed);
      return;
    }
    if (!mounted) return;
    switch (result.status) {
      case SourceSwapApplyStatus.swapped:
        M3ESnackbar.show(
          context,
          message: result.queueFollowed
              ? l10n.sourceSwapQueueFollowed
              : l10n.sourceSwapDone,
        );
        Navigator.of(context).pop();
      case SourceSwapApplyStatus.targetNotFound:
        M3ESnackbar.show(context, message: l10n.sourceSwapNotFound);
      case SourceSwapApplyStatus.duplicateConfirmationRequired:
        break; // 已在上面处理后重试；走到这里说明状态异常，保持弹层。
    }
  }

  /// 时长 → `m:ss`；未知/非法时长返回 null（不占行尾）。
  String? _durationText(Duration? duration) {
    final milliseconds = duration?.inMilliseconds ?? 0;
    if (milliseconds <= 0) return null;
    final value = Duration(milliseconds: milliseconds);
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '${value.inMinutes}:$seconds';
  }
}
