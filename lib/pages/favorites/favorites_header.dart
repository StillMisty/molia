/// 收藏页头部：标题行 / 搜索行 / 调整顺序行 / 多选栏，以及两态交叉淡化。
///
/// 所有依赖都由 [FavoritesHeaderData] / [FavoritesSelectionHeaderData] 显式
/// 传入（值 + 回调）：本文件不认识页面 State，也不从 context 读 provider。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/library.dart';
import '../../domain/models/library_browse.dart';
import '../../domain/models/smart_lists.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/collection_presenter.dart';
import '../../services/haptics.dart';
import '../../theme/m3e_context.dart';
import '../../theme/motion_policy.dart';
import '../../utils/collection_row_query.dart';
import '../../utils/responsive.dart';
import '../../widgets/app_search_bar.dart';
import '../../widgets/collection_spine.dart';
import '../../widgets/icon_swap.dart';
import '../../widgets/playlist_cover.dart';
import 'favorites_models.dart';

/// 标题行 / 搜索行 / 调整顺序行需要的值 + 回调。
class FavoritesHeaderData {
  const FavoritesHeaderData({
    required this.l10n,
    required this.view,
    required this.currentPlaylist,
    required this.searching,
    required this.reorderActive,
    required this.sort,
    required this.libraryIndex,
    required this.mostPlayedByTime,
    required this.canDownloadPlaylist,
    required this.searchController,
    required this.searchFocus,
    required this.onOpenPicker,
    required this.onPlayShuffled,
    required this.onOpenSearch,
    required this.onExitSearch,
    required this.onQueryChanged,
    required this.onExitReorder,
    required this.onEnterReorder,
    required this.onSortChanged,
    required this.onToggleMostPlayedMetric,
    required this.onImportLocal,
    required this.onCheckLocalCache,
    required this.onEditDetails,
    required this.onChangeCover,
    required this.onExport,
    required this.onDownloadPlaylist,
    required this.onClearHistory,
  });

  final AppLocalizations l10n;
  final CollectionView view;

  /// 当前合集对应的落库列表（收藏 / 自建列表）；历史等合集为 null。
  final PlaylistInfo? currentPlaylist;

  final bool searching;
  final bool reorderActive;

  /// 当前排序口径（⋮ 菜单里给选中项打勾）。
  final CollectionTrackSort sort;

  /// 曲库浏览时的专辑 / 歌手索引（其它合集为 null）。
  final LibraryBrowseIndex? libraryIndex;

  /// 智能列表「最多播放」的口径是否为收听时长。
  final bool mostPlayedByTime;

  /// 是否具备批量下载能力（决定 ⋮ 里是否出现「下载全部」）。
  final bool canDownloadPlaylist;

  final TextEditingController searchController;
  final FocusNode searchFocus;

  final VoidCallback onOpenPicker;
  final VoidCallback onPlayShuffled;
  final VoidCallback onOpenSearch;
  final VoidCallback onExitSearch;
  final VoidCallback onQueryChanged;
  final VoidCallback onExitReorder;
  final VoidCallback onEnterReorder;
  final ValueChanged<CollectionTrackSort> onSortChanged;
  final VoidCallback onToggleMostPlayedMetric;
  final VoidCallback onImportLocal;
  final VoidCallback onCheckLocalCache;
  final VoidCallback onEditDetails;
  final VoidCallback onChangeCover;
  final VoidCallback onExport;
  final VoidCallback onDownloadPlaylist;
  final VoidCallback onClearHistory;
}

/// 多选栏需要的值 + 回调。
class FavoritesSelectionHeaderData {
  const FavoritesSelectionHeaderData({
    required this.l10n,
    required this.view,
    required this.selectedCount,
    required this.allSelected,
    required this.allFavorited,
    required this.hasDownloadable,
    required this.onClose,
    required this.onSelectAll,
    required this.onCopyToPlaylist,
    required this.onRemoveFromPlaylist,
    required this.onDeleteHistory,
    required this.onDeleteLocalSongs,
    required this.onToggleFavorite,
    required this.onDownloadSelected,
  });

  final AppLocalizations l10n;
  final CollectionView view;
  final int selectedCount;
  final bool allSelected;

  /// 选中行是否全部已收藏（收藏开关显示「取消收藏」）。
  final bool allFavorited;

  /// 选中行里是否有现在就能下载的曲目（决定 ⋮ 是否出现）。
  final bool hasDownloadable;

  final VoidCallback onClose;
  final VoidCallback onSelectAll;
  final VoidCallback onCopyToPlaylist;
  final VoidCallback onRemoveFromPlaylist;
  final VoidCallback onDeleteHistory;
  final VoidCallback onDeleteLocalSongs;
  final VoidCallback onToggleFavorite;
  final VoidCallback onDownloadSelected;
}

/// 页头三态（常规 / 搜索 / 调整顺序）之一。
Widget buildFavoritesIdleHeader(
  BuildContext context,
  FavoritesHeaderData data,
) {
  if (data.reorderActive) return buildFavoritesReorderHeader(context, data);
  if (data.searching) return buildFavoritesSearchHeader(context, data);
  return buildFavoritesTitleRow(context, data);
}

/// 常驻标题行：合集切换器（弹层）+ 随机 / 搜索 / ⋮（播放暂停在顶栏）。
///
/// 弹层是合集切换与管理的唯一入口：点行切换，弹层内新建 / 重命名 /
/// 删除 / 拖动排序 / 导入收藏都在这里。低频动作全部收进 ⋮。
Widget buildFavoritesTitleRow(BuildContext context, FavoritesHeaderData data) {
  final l10n = data.l10n;
  final view = data.view;
  final theme = Theme.of(context);
  final horizontalPadding = context
      .layoutType(ResponsivePageType.browse)
      .horizontalPadding;
  final missingSmartList =
      view.isSmartList &&
      view.identity.smartListId == SmartListIds.missingFiles;
  final canPlay = view.visibleCount > 0 && !missingSmartList;
  final supportingText = libraryBrowseSummary(l10n, data.libraryIndex);
  // 书脊随标题高度缩放（1× 约 40dp；200% 字号不变成一根小短线）。
  final spine = CollectionSpine(
    height: FavoritesHeaderMetrics.heightOf(context) * 0.72,
  );
  final overflow = _buildHeaderOverflow(context, data);
  return Padding(
    padding: EdgeInsets.fromLTRB(
      horizontalPadding,
      FavoritesHeaderMetrics.paddingTop,
      horizontalPadding,
      FavoritesHeaderMetrics.paddingBottom,
    ),
    child: SizedBox(
      height: FavoritesHeaderMetrics.heightOf(context),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            // 透明底 M3ECard 只借它的交互层：hover / press 状态、焦点环与
            // Enter/Space 激活（裸 InkWell 没有键盘语义）。
            child: M3ECard(
              key: const Key('favoritesTitleSwitcher'),
              variant: M3ECardVariant.filled,
              color: Colors.transparent,
              elevation: 0,
              borderRadius: M3EShapes.radiusMedium,
              padding: EdgeInsets.zero,
              onPressed: () {
                HapticsService.lightImpact();
                data.onOpenPicker();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    if (data.currentPlaylist != null)
                      PlaylistCover(
                        playlist: data.currentPlaylist!,
                        size: 40,
                        borderRadius: 10,
                        fallback: spine,
                      )
                    else
                      spine,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            view.displayName,
                            // 强调字阶自带字重；字距保持合集标题的收紧口径。
                            style: context.emphasizedTypeScale.headlineSmall
                                .copyWith(letterSpacing: -0.4),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (supportingText != null &&
                              supportingText.isNotEmpty)
                            Text(
                              supportingText,
                              style: context.typeScale.bodySmall.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.expand_more_rounded,
                      size: 22,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!view.isLibraryBrowse) ...[
            const SizedBox(width: 8),
            M3EIconButton(
              key: const Key('favoritesShuffleButton'),
              variant: M3EIconButtonVariant.standard,
              semanticLabel: l10n.shufflePlay,
              icon: const Icon(Icons.shuffle_rounded),
              onPressed: canPlay ? data.onPlayShuffled : null,
            ),
          ],
          const SizedBox(width: 4),
          M3EIconButton(
            key: const Key('favoritesSearchButton'),
            variant: M3EIconButtonVariant.standard,
            semanticLabel: l10n.libraryTabSearch,
            icon: const Icon(Icons.search_rounded),
            onPressed: data.onOpenSearch,
          ),
          if (overflow != null) ...[const SizedBox(width: 4), overflow],
        ],
      ),
    ),
  );
}

/// 标题行 ⋮：按合集种类组合低频动作；没有动作时返回 null（不占位置）。
Widget? _buildHeaderOverflow(BuildContext context, FavoritesHeaderData data) {
  final l10n = data.l10n;
  final view = data.view;
  final currentPlaylist = data.currentPlaylist;
  final byTime = data.mostPlayedByTime;
  final entries = <M3EMenuEntry>[
    if (view.isFavorites || view.isCustom || view.isSmartList)
      for (final sort in CollectionTrackSort.values)
        M3EMenuEntry(
          label: switch (sort) {
            CollectionTrackSort.added => l10n.sortDefaultOrder,
            CollectionTrackSort.title => l10n.sortByTitle,
            CollectionTrackSort.artist => l10n.sortByArtist,
          },
          value: sort,
          leading: data.sort == sort
              ? const Icon(Icons.check_rounded, size: 20)
              : null,
        ),
    if (view.isCustom && view.tracks.length >= 2)
      M3EMenuEntry(
        label: l10n.playlistReorder,
        value: 'reorder',
        leading: const Icon(Icons.drag_handle_rounded, size: 20),
      ),
    if (view.isSmartList &&
        view.identity.smartListId == SmartListIds.mostPlayed)
      M3EMenuEntry(
        label: byTime
            ? l10n.smartMetricPlayCount
            : l10n.smartMetricListeningTime,
        value: 'metric',
        leading: Icon(
          byTime ? Icons.format_list_numbered_rounded : Icons.schedule_rounded,
          size: 20,
        ),
      ),
    if (view.isLocalSongs)
      M3EMenuEntry(
        label: l10n.libraryImportLocalSongs,
        value: 'importLocal',
        leading: const Icon(Icons.audio_file_rounded, size: 20),
      ),
    if (view.isLocalSongs)
      M3EMenuEntry(
        label: l10n.localCacheCheck,
        value: 'checkLocalCache',
        leading: const Icon(Icons.fact_check_rounded, size: 20),
      ),
    if (view.isCustom && currentPlaylist != null)
      M3EMenuEntry(
        label: l10n.playlistEditDetails,
        value: 'details',
        leading: const Icon(Icons.edit_rounded, size: 20),
      ),
    if ((view.isFavorites || view.isCustom) && currentPlaylist != null)
      M3EMenuEntry(
        label: l10n.playlistCoverChange,
        value: 'cover',
        leading: const Icon(Icons.image_rounded, size: 20),
      ),
    if (currentPlaylist != null)
      M3EMenuEntry(
        label: l10n.playlistExport,
        value: 'export',
        leading: const Icon(Icons.file_upload_rounded, size: 20),
      ),
    if (currentPlaylist != null &&
        data.canDownloadPlaylist &&
        view.tracks.isNotEmpty)
      M3EMenuEntry(
        label: l10n.downloadAll,
        value: 'download',
        leading: const Icon(Icons.download_rounded, size: 20),
      ),
    if (view.isHistory)
      M3EMenuEntry(
        label: l10n.historyClear,
        value: 'clearHistory',
        isDestructive: true,
        leading: const Icon(Icons.delete_outline_rounded, size: 20),
      ),
  ];
  if (entries.isEmpty) return null;
  return M3EMenu.entries(
    position: M3EMenuAnchorPosition.bottomEnd,
    anchorBuilder: (context, open) => M3EIconButton(
      key: const Key('favoritesHeaderOverflow'),
      variant: M3EIconButtonVariant.standard,
      icon: const Icon(Icons.more_vert_rounded),
      semanticLabel: l10n.moreActions,
      onPressed: open,
    ),
    onSelected: (value) {
      if (value is CollectionTrackSort) {
        data.onSortChanged(value);
        return;
      }
      switch (value) {
        case 'reorder':
          data.onEnterReorder();
        case 'metric':
          data.onToggleMostPlayedMetric();
        case 'importLocal':
          data.onImportLocal();
        case 'checkLocalCache':
          data.onCheckLocalCache();
        case 'details':
          data.onEditDetails();
        case 'cover':
          data.onChangeCover();
        case 'export':
          data.onExport();
        case 'download':
          data.onDownloadPlaylist();
        case 'clearHistory':
          data.onClearHistory();
      }
    },
    entries: entries,
  );
}

/// 搜索行：只有一个输入胶囊（返回键 + 输入 / 清除）；排序 / 调整顺序 /
/// 清空历史已在标题行的 ⋮ 里，搜索态不再挂第二套动作。
Widget buildFavoritesSearchHeader(
  BuildContext context,
  FavoritesHeaderData data,
) {
  final horizontalPadding = context
      .layoutType(ResponsivePageType.browse)
      .horizontalPadding;
  return Padding(
    padding: EdgeInsets.fromLTRB(
      horizontalPadding,
      FavoritesHeaderMetrics.paddingTop,
      horizontalPadding,
      FavoritesHeaderMetrics.paddingBottom,
    ),
    // 不套固定高度：AppSearchBar 会随系统文字缩放长高，父级再钉 56 会把
    // hint 压回裁切；搜索态头部允许比标题行高。
    child: AppSearchBar(
      controller: data.searchController,
      focusNode: data.searchFocus,
      hintText: data.l10n.favoritesSearchHint,
      leading: M3EIconButton(
        variant: M3EIconButtonVariant.standard,
        semanticLabel: data.l10n.cancel,
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: data.onExitSearch,
      ),
      onChanged: (_) => data.onQueryChanged(),
    ),
  );
}

/// 排序模式行：标题 + 提示 + 完成。
Widget buildFavoritesReorderHeader(
  BuildContext context,
  FavoritesHeaderData data,
) {
  final theme = Theme.of(context);
  final horizontalPadding = context
      .layoutType(ResponsivePageType.browse)
      .horizontalPadding;
  return Padding(
    padding: EdgeInsets.fromLTRB(
      horizontalPadding,
      FavoritesHeaderMetrics.paddingTop,
      horizontalPadding,
      FavoritesHeaderMetrics.paddingBottom,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Container(
                    width: 5,
                    height: 38,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: M3EShapes.radiusExtraSmall,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      data.view.displayName,
                      style: context.emphasizedTypeScale.headlineSmall.copyWith(
                        letterSpacing: -0.4,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            M3EIconButton(
              variant: M3EIconButtonVariant.filled,
              semanticLabel: data.l10n.playlistReorderDone,
              icon: const Icon(Icons.done_rounded),
              onPressed: data.onExitReorder,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 17),
          child: Text(
            data.l10n.playlistReorderHint,
            style: context.typeScale.labelMedium.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 多选上下文栏（单行紧凑版）：关闭 / 已选计数 / 全选 / 批量操作。
///
/// 自绘而非 M3ESelectionAppBar：后者在页面内会叠加状态栏安全区，且
/// 「全选」独占一行导致顶栏过高（收藏页顶部已有应用栏，不需要再留安全区）。
Widget buildFavoritesSelectionBar(
  BuildContext context,
  FavoritesSelectionHeaderData data,
) {
  final m3e = M3ETheme.of(context);
  final selectionTheme = m3e.selectionTheme;
  final foreground = selectionTheme.contextualForeground(m3e.colorScheme);
  return DecoratedBox(
    decoration: BoxDecoration(
      color: selectionTheme.contextualBackground(m3e.colorScheme),
      // 选中栏只在多选时出现：圆底 + 一条低对比分隔线把它与列表分开，
      // 不抢标题行的层级，也不用阴影（M3E 列表表面本来就没有阴影）。
      borderRadius: const BorderRadius.vertical(
        bottom: Radius.circular(M3EShapes.large),
      ),
      border: Border(
        bottom: BorderSide(color: foreground.withValues(alpha: 0.12)),
      ),
    ),
    // 与标题行 / 搜索行同一套垂直留白：进入 / 退出多选头部不跳高。
    child: Padding(
      padding: const EdgeInsets.only(
        top: FavoritesHeaderMetrics.paddingTop,
        bottom: FavoritesHeaderMetrics.paddingBottom,
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: foreground),
        child: SizedBox(
          height: FavoritesHeaderMetrics.heightOf(context),
          child: Row(
            children: [
              const SizedBox(width: 4),
              M3EIconButton(
                key: const Key('collectionSelectionClose'),
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(Icons.close_rounded),
                semanticLabel: data.l10n.cancel,
                onPressed: data.onClose,
              ),
              // 计数是纯文本（没有上限，也没有胶囊 / 警告色）。
              Text(
                data.l10n.selectionCountSelected(data.selectedCount),
                key: const Key('collectionSelectionCount'),
                style: m3e.typeScale.titleSmall.copyWith(color: foreground),
              ),
              const Spacer(),
              // 全选只负责选中；清空 / 退出只走 ✕。
              M3EIconButton(
                key: const Key('collectionSelectionSelectAll'),
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(Icons.select_all_rounded),
                semanticLabel: data.l10n.selectAllItems,
                onPressed: data.allSelected ? null : data.onSelectAll,
              ),
              ..._buildSelectionActions(data),
              _buildSelectionOverflow(data),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 多选栏只保留两个高频动作（按合集种类定），其余批量动作收进 ⋮。
List<Widget> _buildSelectionActions(FavoritesSelectionHeaderData data) {
  if (data.selectedCount == 0) return const [];
  final l10n = data.l10n;
  final addToPlaylist = M3EIconButton(
    key: const Key('collectionSelectionAddToPlaylist'),
    variant: M3EIconButtonVariant.standard,
    icon: const Icon(Icons.playlist_add_rounded),
    semanticLabel: l10n.addToPlaylist,
    onPressed: data.onCopyToPlaylist,
  );
  if (data.view.isCustom) {
    return [
      M3EIconButton(
        key: const Key('collectionSelectionRemove'),
        variant: M3EIconButtonVariant.standard,
        icon: const Icon(Icons.playlist_remove_rounded),
        semanticLabel: l10n.playlistRemoveTrack,
        onPressed: data.onRemoveFromPlaylist,
      ),
      addToPlaylist,
    ];
  }
  if (data.view.isHistory) {
    return [
      M3EIconButton(
        key: const Key('collectionSelectionDelete'),
        variant: M3EIconButtonVariant.standard,
        icon: const Icon(Icons.delete_rounded),
        semanticLabel: l10n.historyDeleteEntry,
        onPressed: data.onDeleteHistory,
      ),
      addToPlaylist,
    ];
  }
  if (data.view.isLocalSongs) {
    return [
      M3EIconButton(
        key: const Key('collectionSelectionDelete'),
        variant: M3EIconButtonVariant.standard,
        icon: const Icon(Icons.delete_rounded),
        semanticLabel: l10n.delete,
        onPressed: data.onDeleteLocalSongs,
      ),
      addToPlaylist,
    ];
  }
  // 收藏 / 智能列表：收藏开关 + 加入列表（全部已收藏时开关变取消）。
  return [
    M3EIconButton(
      key: const Key('collectionSelectionFavorite'),
      variant: M3EIconButtonVariant.standard,
      icon: IconSwap<bool>(
        value: data.allFavorited,
        builder: (context, allFavorited) => Icon(
          allFavorited
              ? Icons.heart_broken_rounded
              : Icons.favorite_border_rounded,
        ),
      ),
      semanticLabel: data.allFavorited ? l10n.favoriteRemove : l10n.favoriteAdd,
      onPressed: data.onToggleFavorite,
    ),
    addToPlaylist,
  ];
}

/// 多选栏 ⋮：下载等低频批量动作只在这里出现，避免选中栏变成功作墙。
Widget _buildSelectionOverflow(FavoritesSelectionHeaderData data) {
  if (!data.hasDownloadable) return const SizedBox.shrink();
  return M3EMenu.entries(
    position: M3EMenuAnchorPosition.bottomEnd,
    anchorBuilder: (context, open) => M3EIconButton(
      variant: M3EIconButtonVariant.standard,
      icon: const Icon(Icons.more_vert_rounded),
      semanticLabel: data.l10n.moreActions,
      onPressed: open,
    ),
    onSelected: (value) {
      if (value == 'download') data.onDownloadSelected();
    },
    entries: [
      M3EMenuEntry(
        label: data.l10n.playlistDownloadSelected,
        value: 'download',
        leading: const Icon(Icons.download_rounded),
      ),
    ],
  );
}

/// 页头两态（常规 / 多选）交叉淡入淡出。
///
/// 两态高度相同（顶部 / 底部留白 + 56 行高），避免切换时头部跳高、列表
/// 滚动位置抖动。落定后只挂当前层：隐藏态不参与 finder / 焦点 / 点击。
/// 用自绘控制器而不是 `AnimatedSwitcher`（图标切换专用，架构测试会拦），
/// 也不直接用 `AnimatedCrossFade`（隐藏层仍留在树里，测试与焦点会命中原层）。
class FavoritesHeaderCrossFade extends StatefulWidget {
  const FavoritesHeaderCrossFade({
    required this.selecting,
    required this.idle,
    required this.selection,
    super.key,
  });

  final bool selecting;
  final Widget idle;
  final Widget selection;

  @override
  State<FavoritesHeaderCrossFade> createState() =>
      _FavoritesHeaderCrossFadeState();
}

class _FavoritesHeaderCrossFadeState extends State<FavoritesHeaderCrossFade>
    with SingleTickerProviderStateMixin {
  static const Duration _duration = M3EMotion.short4;

  late final AnimationController _progress = AnimationController(
    vsync: this,
    value: widget.selecting ? 1 : 0,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // effects 时长随系统减弱动效归零（硬切）。
    _progress.duration = effectDurationOf(context, _duration);
  }

  @override
  void didUpdateWidget(covariant FavoritesHeaderCrossFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selecting == widget.selecting) return;
    final double target = widget.selecting ? 1 : 0;
    if (_progress.duration == Duration.zero) {
      _progress.value = target;
      return;
    }
    _progress.animateTo(target, curve: M3EMotion.emphasizedDecelerate);
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        final double t = _progress.value;
        // 落定后只保留当前态：隐藏层不再构建（finder / 键盘焦点 / 语义都
        // 不会命中已经离开的页头）。
        if (t <= 0) {
          return IgnorePointer(ignoring: widget.selecting, child: widget.idle);
        }
        if (t >= 1) {
          return IgnorePointer(
            ignoring: !widget.selecting,
            child: widget.selection,
          );
        }
        return Stack(
          alignment: Alignment.topCenter,
          children: [
            IgnorePointer(
              ignoring: widget.selecting,
              child: Opacity(opacity: 1 - t, child: widget.idle),
            ),
            IgnorePointer(
              ignoring: !widget.selecting,
              child: Opacity(opacity: t, child: widget.selection),
            ),
          ],
        );
      },
    );
  }
}
