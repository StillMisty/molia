import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../models/play_mode.dart';
import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../services/library/playlist_batch_create.dart';
import '../theme/m3e_context.dart';
import '../utils/responsive.dart';
import 'add_to_playlist_sheet.dart' show showPlaylistNameDialog;
import 'row_actions.dart';
import 'track_menu_tile.dart';
import 'track_row.dart';
import 'track_row_actions.dart';

/// 封面地址：缺失 / 空串返回 null（行内不占位）。
String? _coverUrlOf(Track track) {
  final url = track.artwork?.uri.toString();
  return url == null || url.isEmpty ? null : url;
}

/// 队列没有待播行时的尾态文案。
///
/// `upNext` 为空不等于「队列为空」：最后一首、随机轮末、单曲循环都有当前
/// 曲目，只是后面没有待播项；随机恢复态也有本轮顺序，只有真正到轮末
/// （或队列只剩一首）才没有待播行。
String _emptyQueueText({
  required AppLocalizations l10n,
  required bool hasTrack,
  required int queueLength,
  required PlayMode mode,
}) {
  if (!hasTrack) return l10n.currentQueueEmpty;
  switch (mode) {
    // 单曲循环优先说「会重播当前」：即使队列只有一首，这比「没有待播」
    // 更准确（自动播完本来就回到当前曲目）。
    case PlayMode.singleRepeat:
      return l10n.queueSingleRepeat;
    case PlayMode.shuffle:
      if (queueLength <= 1) return l10n.queueNoUpcoming;
      return l10n.queueShuffleRoundEnd;
    case PlayMode.sequential:
    case PlayMode.listLoop:
      return l10n.queueNoUpcoming;
  }
}

/// 播放队列：只列出当前曲目之后的曲目。
///
/// 当前播放曲目由上方播放器承载（封面/标题/进度），列表里不重复这一行；
/// 需要内嵌当前行的宿主（测试 / 未来的内嵌面板）可传
/// [QueueDisplay.includeCurrent]，此时在列表之前补一段高亮、不可点的
/// 「正在播放」小节。生产版式（播放页 / 桌面右栏）都不传，当前曲目由播放器
/// 承载。
/// 懒加载：`SliverFixedExtentList` + [TrackRow] 固定行高，队列再长也只构建
/// 视口附近的行、只请求视口内的封面；固定 extent 让滚动条拇指尺寸与拖动
/// 定位精确（`interactive` + `thumbVisibility`，可手按住拖动）。
///
/// 恢复态（冷启动未真正加载）同样可用：点击条目会从该曲目恢复播放。
///
/// 列表不再分「正在播放 / 接下来」两段小标题：面板本身就是队列
/// （tab 文案已说明分组），标题只会把首行往下推。
class QueueDisplay extends StatelessWidget {
  const QueueDisplay({
    super.key,
    required this.controller,
    this.topPadding = 0,
    this.includeCurrent = false,
  });

  /// 队列滚动控制器（滚动条与父页面「滑到顶下拉收起」共用）。
  final ScrollController controller;

  /// 内容顶部额外留白（播放页圆点过渡带 / 桌面版式 tab 栏下的内容间距）。
  final double topPadding;

  /// 是否在顶部补一行「正在播放」（当前曲目，高亮、不可点）。
  ///
  /// 生产版式里当前曲目由播放器承载，保持 false 不重复展示；只有测试 /
  /// 未来的内嵌面板需要把当前曲目也嵌进列表时传 true。
  final bool includeCurrent;

  /// 「正在播放」小节与队列列表之间的空气：比行距大，避免两段视觉上粘成一段。
  static const double _sectionSpacing = 16;

  /// 队列一键存为列表：新建一个列表，按队列存储顺序批量加入。
  ///
  /// 失败（创建成功但批量写入失败）删除刚建的空列表，不在侧栏留下半成品；
  /// 重复键由存储层跳过，结果只报 added / skipped。
  static Future<void> _saveQueueAsPlaylist(
    BuildContext context,
    List<Track> queue,
  ) async {
    final provider = context.read<LibraryProvider?>();
    if (provider == null || queue.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final contextName = context
        .read<PlaybackProvider?>()
        ?.snapshot
        .context
        ?.name
        ?.trim();
    final name = await showPlaylistNameDialog(
      context,
      title: l10n.playlistCreate,
      confirmLabel: l10n.playlistCreateConfirm,
      existingNames: [for (final item in provider.playlists) item.name],
      initialValue: (contextName ?? '').isEmpty
          ? l10n.queuePlaylistDefaultName
          : contextName!,
    );
    if (name == null || !context.mounted) return;
    try {
      final result = await createPlaylistWithRollback<({int added})>(
        name: name,
        createPlaylist: provider.createPlaylist,
        write: (playlistId) async {
          final addedAt = DateTime.now().millisecondsSinceEpoch;
          final outcome = await provider.addTracksToPlaylist(playlistId, [
            for (final track in queue)
              PlaylistTrack.fromTrack(track, addedAt: addedAt),
          ]);
          if (outcome.isFailure) {
            throw PlaylistBatchWriteException(outcome.error);
          }
          return (added: outcome.changed);
        },
        deletePlaylist: (playlistId) async {
          await provider.deletePlaylist(playlistId);
        },
      );
      if (!context.mounted) return;
      M3ESnackbar.show(
        context,
        message: l10n.queueSavedAsPlaylist(
          name,
          result.added,
          queue.length - result.added,
        ),
      );
    } catch (_) {
      if (context.mounted) {
        M3ESnackbar.show(context, message: l10n.queueSaveFailed);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cardList = M3ETheme.of(context).listTheme.cardList;

    // 队列视图一次取齐播放顺序 / 真实队列下标 / 当前下标 / 模式 / 是否有
    // 当前曲目：record 只在队列快照变化时失效（进度 tick / 无关通知不会重建
    // 列表）。hasTrack 不能从 upNext 是否为空反推——最后一首 / 随机轮末 /
    // 单曲循环都有当前曲目，只是后面没有待播项。
    final queueState = context
        .select<
          PlaybackProvider,
          ({
            List<Track> tracks,
            List<int> indices,
            int currentIndex,
            int queueLength,
            List<Track> queue,
            PlayMode mode,
            bool hasTrack,
          })
        >((provider) {
          final snapshot = provider.snapshot;
          return (
            tracks: snapshot.upNext,
            indices: snapshot.upNextIndices,
            currentIndex: snapshot.currentIndex,
            queueLength: snapshot.queue.length,
            queue: snapshot.queue,
            mode: snapshot.mode,
            hasTrack: snapshot.current != null,
          );
        });
    final currentQueue = queueState.tracks;
    // 旧快照 / 测试未填下标时不做队列编辑（真实下标未知，猜行号会移错歌）；
    // 公共动作仍按行展示，列表本身不崩。
    final upNextIndices = queueState.indices.length == currentQueue.length
        ? queueState.indices
        : const <int>[];
    // 当前曲目只归「正在播放」小节；播放页版式不订阅，避免无关重建。
    final Track? current = includeCurrent
        ? context.select<PlaybackProvider, Track?>(
            (provider) => provider.snapshot.current,
          )
        : null;
    final playbackProvider = context.read<PlaybackProvider>();

    return Scrollbar(
      controller: controller,
      thumbVisibility: true,
      interactive: true,
      child: CustomScrollView(
        controller: controller,
        slivers: [
          // 队列唯一溢出动作：队列非空时才出现，不占常驻工具栏。
          if (queueState.queue.isNotEmpty)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(16, topPadding, 4, 0),
              sliver: SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: M3EMenu.entries(
                    position: M3EMenuAnchorPosition.bottomEnd,
                    anchorBuilder: (context, open) => M3EIconButton(
                      key: const Key('queueOverflow'),
                      variant: M3EIconButtonVariant.standard,
                      semanticLabel: l10n.queueSaveAsPlaylist,
                      icon: const Icon(Icons.more_vert_rounded),
                      onPressed: open,
                    ),
                    onSelected: (value) {
                      if (value == 'save') {
                        unawaited(
                          _saveQueueAsPlaylist(context, queueState.queue),
                        );
                      }
                    },
                    entries: [
                      M3EMenuEntry(
                        label: l10n.queueSaveAsPlaylist,
                        value: 'save',
                        leading: const Icon(
                          Icons.playlist_add_rounded,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // 「正在播放」小节（无当前曲目时整段不存在）。
          if (current != null)
            SliverPadding(
              // 左右 16 与 tab 栏 / 其它内容同一内容边距（M3E 口径）。
              padding: EdgeInsets.fromLTRB(16, topPadding, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _sectionLabel(context, l10n.queuePanelNowPlaying),
                    // 当前曲目：高亮但不翻选中勾，也不响应点击——它本身就是
                    // 正在播放的进度行，重复装载同一曲目没有意义。
                    TrackRow(
                      model: TrackRowModel(
                        title: current.title,
                        artist: current.artistLabel,
                        coverUrl: _coverUrlOf(current),
                        durationMs: current.duration?.inMilliseconds,
                        trackId: current.id,
                        selected: true,
                      ),
                      surface: const TrackRowSurface(
                        coverSize: 40,
                        showCheckWhenSelected: false,
                      ),
                      // 单行小节 = 四周外圆角（calculateCardPosition(0, 1) 约定）。
                      position: M3ECardPosition.single,
                    ),
                  ],
                ),
              ),
            ),
          if (currentQueue.isNotEmpty)
            SliverPadding(
              // 有「正在播放」段时用小节间距分隔两段；否则沿用顶部留白
              // （播放页圆点过渡带 / tab 栏下的内容间距）。
              padding: EdgeInsets.fromLTRB(
                16,
                current != null ? _sectionSpacing : topPadding,
                16,
                0,
              ),
              sliver: SliverFixedExtentList.builder(
                // 行高 + 行距：与行内 SizedBox 同一动态口径（大字号不裁切）。
                itemExtent:
                    TrackRow.extentOf(context, tableColumns: false) +
                    cardList.gap,
                itemCount: currentQueue.length,
                itemBuilder: (context, index) {
                  final track = currentQueue[index];
                  final isLast = index == currentQueue.length - 1;
                  final queueIndex = upNextIndices.isEmpty
                      ? null
                      : upNextIndices[index];
                  return Column(
                    children: [
                      _QueueTrackRow(
                        track: track,
                        position: calculateCardPosition(
                          index,
                          currentQueue.length,
                        ),
                        queueIndex: queueIndex,
                        currentIndex: queueState.currentIndex,
                        queueLength: queueState.queueLength,
                        mode: queueState.mode,
                        playbackProvider: playbackProvider,
                        onTap: () {
                          // 用真实队列下标定位：随机排列 / 列表循环回绕时
                          // 面板行号与队列下标不同，重复曲目按 id 反查会
                          // 串到第一项（队列允许同一首出现多次）。
                          final index = queueIndex;
                          if (index != null) {
                            unawaited(playbackProvider.playQueueIndex(index));
                          } else {
                            unawaited(
                              playbackProvider.playLocalQueueItemById(
                                track.id.uri,
                              ),
                            );
                          }
                        },
                      ),
                      if (!isLast) SizedBox(height: cardList.gap),
                    ],
                  );
                },
              ),
            )
          else if (current == null)
            // 「正在播放」小节存在时不显示空态；播放页 / 桌面右栏的当前曲目
            // 由播放器承载，此时按「有没有当前曲目 + 模式」给出真实的尾态
            // 文案：最后一首 / 单曲循环 / 随机轮末都不是「队列为空」。
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _emptyQueueText(
                      l10n: l10n,
                      hasTrack: queueState.hasTrack,
                      queueLength: queueState.queueLength,
                      mode: queueState.mode,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          // 单曲循环时列表仍列着后面的歌，但自动播完会重播当前曲目；尾部
          // 补一句口径，避免把「接下来」误读成会自动前进。
          if (queueState.mode == PlayMode.singleRepeat &&
              currentQueue.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Text(
                  l10n.queueSingleRepeatHint,
                  textAlign: TextAlign.center,
                  style: context.typeScale.bodySmall.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
      ),
    );
  }

  /// 分组标签：与列表行文字同一文本契约（次要信息用 onSurfaceVariant）。
  Widget _sectionLabel(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
      child: Text(
        text,
        style: context.typeScale.labelMedium.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 队列行：行内容 + 队列编辑动作 + 公共动作。
///
/// 入口分平台：桌面端行表面右键在落点弹菜单；触摸端行尾常显 ⋮。
/// 可编辑边界由真实队列下标决定（[queueIndex] 为 null = 快照未带下标，
/// 只展示公共动作）：
/// - 当前曲目不可编辑；
/// - 随机模式 / 列表循环回绕到当前曲目之前的行只保留「移出队列」；
/// - 上移 / 下移跨不过当前曲目，首行没有上移、队尾没有下移。
class _QueueTrackRow extends StatelessWidget {
  const _QueueTrackRow({
    required this.track,
    required this.position,
    required this.queueIndex,
    required this.currentIndex,
    required this.queueLength,
    required this.mode,
    required this.playbackProvider,
    required this.onTap,
  });

  final Track track;
  final M3ECardPosition position;

  /// 本行在完整队列中的真实下标；null = 快照没带下标（不做编辑动作）。
  final int? queueIndex;
  final int currentIndex;
  final int queueLength;
  final PlayMode mode;
  final PlaybackProvider playbackProvider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final actions = _actions(context);
    final queueActions = _queueActions(context);
    // 屏幕阅读器直接给出与菜单同边界的移动 / 移除动作；当前行与不可移动
    // 行不会出现在集合里（与可见菜单同一判定）。
    final customActions = <CustomSemanticsAction, VoidCallback>{
      for (final action in queueActions)
        CustomSemanticsAction(label: action.label): action.onPressed,
    };
    return Semantics(
      key: ValueKey<String>('queueRowSemantics-${queueIndex ?? 'none'}'),
      customSemanticsActions: customActions,
      child: TrackRow(
        model: TrackRowModel(
          title: track.title,
          artist: track.artistLabel,
          coverUrl: _coverUrlOf(track),
          durationMs: track.duration?.inMilliseconds,
          trackId: track.id,
        ),
        surface: const TrackRowSurface(coverSize: 40),
        position: position,
        onTap: onTap,
        onSecondaryTap: rowActionsAtPointer(context, actions),
        trailing: isDesktopPlatform() || actions.isEmpty
            ? null
            : RowActionMenuButton(
                actions: actions,
                semanticLabel: AppLocalizations.of(context)!
                    .trackActionsTooltip,
                compact: true,
              ),
      ),
    );
  }

  List<RowAction> _actions(BuildContext context) {
    final common = trackRowActionMenuForTrack(
      context,
      track,
      includeAddToQueue: false,
    );
    return mergeRowActions(_queueActions(context), common);
  }

  /// 队列编辑动作：边界由真实队列下标决定（当前行 / 回绕行不出现）。
  List<RowAction> _queueActions(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final index = queueIndex;
    if (index == null) return const [];
    final shuffle = mode == PlayMode.shuffle;
    // 列表循环的 upNext 末尾会补上队首到当前之前的行：这些行已在当前曲目
    // 之前，移动没有意义（只保留移除）。
    final wrapped = index < currentIndex;
    final allowed = !shuffle && !wrapped;
    final queueActions = <RowAction>[
      if (allowed && index != currentIndex + 1)
        RowAction(
          icon: Icons.playlist_play_rounded,
          label: l10n.playNext,
          onPressed: () => unawaited(
            playbackProvider.moveQueueIndex(index, currentIndex + 1),
          ),
        ),
      if (allowed && index > currentIndex + 1)
        RowAction(
          icon: Icons.arrow_upward_rounded,
          label: l10n.moveQueueUp,
          onPressed: () =>
              unawaited(playbackProvider.moveQueueIndex(index, index - 1)),
        ),
      if (allowed && index < queueLength - 1)
        RowAction(
          icon: Icons.arrow_downward_rounded,
          label: l10n.moveQueueDown,
          onPressed: () =>
              unawaited(playbackProvider.moveQueueIndex(index, index + 1)),
        ),
    ];
    final removable = index != currentIndex;
    if (removable) {
      queueActions.add(
        RowAction(
          icon: Icons.playlist_remove_rounded,
          label: l10n.removeFromQueue,
          destructive: true,
          onPressed: () => unawaited(playbackProvider.removeQueueIndex(index)),
        ),
      );
    }
    return queueActions;
  }
}
