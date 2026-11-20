/// 收藏页正文：列表 / 表格 / 空态 / 读取失败 / 曲库浏览。
///
/// 行渲染只消费 [FavoritesBodyData]（值 + 回调）；行动作仍由页面接线后
/// 通过 [FavoritesBodyData.rowActionsFor] 注入，本文件不做 provider 读取。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../domain/models/library_browse.dart';
import '../../domain/models/smart_lists.dart';
import '../../domain/models/track.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/collection_actions.dart';
import '../../providers/collection_mode.dart';
import '../../providers/collection_presenter.dart';
import '../../providers/favorites_view_model.dart';
import '../../providers/library_provider.dart';
import '../../providers/local_library_provider.dart';
import '../../providers/lyrics_provider.dart';
import '../../services/download/download_records.dart';
import '../../theme/m3e_context.dart';
import '../../widgets/responsive.dart';
import '../../utils/sync_format.dart';
import '../../widgets/adaptive_layout.dart';
import '../../widgets/collection_mode_switch.dart';
import '../../widgets/collection_track_list.dart';
import '../../widgets/desktop_layout.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/library_browse_view.dart';
import '../../widgets/local_audio_import.dart' show importLocalAudioFilesFlow;
import '../../widgets/row_actions.dart';
import '../../widgets/track_row.dart';
import '../../widgets/track_table_header.dart';
import 'favorites_actions.dart';

/// 正文列表 / 表格分支的输入。
class FavoritesBodyData {
  const FavoritesBodyData({
    required this.l10n,
    required this.view,
    required this.rows,
    required this.columnSpec,
    required this.reorderActive,
    required this.selecting,
    required this.controller,
    required this.smartVersionCounts,
    required this.isSelected,
    required this.isMissingRow,
    required this.onToggleSmartVersions,
    required this.onRowTap,
    required this.onRowTapWithModifiers,
    required this.onRowLongPress,
    required this.onReorder,
    required this.rowActionsFor,
    required this.onImportLocal,
  });

  final AppLocalizations l10n;
  final CollectionView view;

  /// 实际渲染的行（智能列表已按重复版本展开）。
  final List<CollectionRow> rows;

  final TrackRowColumnSpec? columnSpec;
  final bool reorderActive;
  final bool selecting;

  final ScrollController controller;

  /// 智能列表重复版本计数（按代表行 key）。
  final Map<String, int> smartVersionCounts;

  final bool Function(String key) isSelected;
  final bool Function(CollectionRow row) isMissingRow;
  final void Function(CollectionRow row) onToggleSmartVersions;
  final void Function(int index) onRowTap;
  final void Function(int index, {required bool ctrl, required bool shift})
  onRowTapWithModifiers;
  final void Function(String key) onRowLongPress;
  final Future<void> Function(int from, int to) onReorder;

  /// 行动作构成：由页面把会话 / 动作端口接好后注入。
  final List<RowAction> Function(BuildContext rowContext, CollectionRow row)
  rowActionsFor;

  final VoidCallback onImportLocal;
}

/// 列表 / 表格正文。表格列只在内容宽足够时出现（[columnSpec] 非空）。
Widget buildFavoritesCollectionBody(
  BuildContext context, {
  required AppLocalizations l10n,
  required CollectionView view,
  required List<CollectionRow> rows,
  required bool reorderActive,
  required bool selecting,
  required ScrollController controller,
  required Map<String, int> smartVersionCounts,
  required bool Function(String key) isSelected,
  required bool Function(CollectionRow row) isMissingRow,
  required void Function(CollectionRow row) onToggleSmartVersions,
  required void Function(int index) onRowTap,
  required void Function(int index, {required bool ctrl, required bool shift})
  onRowTapWithModifiers,
  required void Function(String key) onRowLongPress,
  required Future<void> Function(int from, int to) onReorder,
  required List<RowAction> Function(BuildContext rowContext, CollectionRow row)
  rowActionsFor,
  required VoidCallback onImportLocal,
  required void Function(List<CollectionRow> rows, TrackRowSurface surface)
  onRowsReady,
}) {
  // 行 / 表头同一份列规范：只有播放历史多一列「播放时间」。
  final spec = view.isHistory
      ? TrackRowColumnSpec.history
      : TrackRowColumnSpec.standard;
  final columnSpec = DesktopLayout.of(context).tableColumnsFor(spec)
      ? spec
      : null;
  final rowSurface = TrackRowSurface(tableSpec: columnSpec);
  onRowsReady(rows, rowSurface);
  return buildFavoritesBody(
    context,
    FavoritesBodyData(
      l10n: l10n,
      view: view,
      rows: rows,
      columnSpec: columnSpec,
      reorderActive: reorderActive,
      selecting: selecting,
      controller: controller,
      smartVersionCounts: smartVersionCounts,
      isSelected: isSelected,
      isMissingRow: isMissingRow,
      onToggleSmartVersions: onToggleSmartVersions,
      onRowTap: onRowTap,
      onRowTapWithModifiers: onRowTapWithModifiers,
      onRowLongPress: onRowLongPress,
      onReorder: onReorder,
      rowActionsFor: rowActionsFor,
      onImportLocal: onImportLocal,
    ),
  );
}

/// 列表 / 表格正文。表格列只在内容宽足够时出现（[columnSpec] 非空）。
Widget buildFavoritesBody(BuildContext context, FavoritesBodyData data) {
  final rowSurface = TrackRowSurface(tableSpec: data.columnSpec);
  // 窄窗口：简洁双行列表（历史播放时间进副标题）。宽窗口：表格列填满
  // 行中段，避免标题与行尾时长之间留出大片空白。
  final body = CollectionTrackList<CollectionRow>(
    controller: data.controller,
    rows: data.rows,
    keyOf: (row) => ValueKey<String>(row.key),
    // 合集本身为空 → 合集空态；有内容但被搜索过滤掉 → 搜索空态。
    empty: data.view.hasItems
        ? CollectionSearchEmpty(message: data.l10n.favoritesSearchEmpty)
        : buildFavoritesEmptyState(context, data),
    onReorder: data.reorderActive
        ? (from, to) => unawaited(data.onReorder(from, to))
        : null,
    // 行高与行渲染同档（表格 56 / 双行 72）：同一份 surface 同时决定
    // itemExtent 与行内版式，差一档滚动条拇指与拖动定位就落在错误位置。
    surface: rowSurface,
    itemBuilder: (context, row, index) =>
        buildFavoritesRow(context, data, row, index, rowSurface),
  );
  // 表头固定在滚动区之上（与搜索页同一口径）：列标题不随列表滚走，
  // 列与行内列同宽同左缘。空列表（含被搜索过滤空）不给表头。
  if (data.columnSpec == null || data.view.visibleCount == 0) return body;
  final horizontalPadding = context
      .layoutType(ResponsivePageType.browse)
      .horizontalPadding;
  return Column(
    children: [
      Padding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        child: TrackTableHeader(spec: data.columnSpec!),
      ),
      Expanded(child: body),
    ],
  );
}

/// 三种合集共用同一行外壳：展示字段来自行联合，行尾标签 / 拖动把手与
/// 行动作按行变体分派；点播 / 多选 / 排序手势与既有语义一致。
Widget buildFavoritesRow(
  BuildContext context,
  FavoritesBodyData data,
  CollectionRow row,
  int index,
  TrackRowSurface rowSurface,
) {
  final l10n = data.l10n;
  final table = data.columnSpec != null;
  final playedAtText = row is HistoryCollectionRow
      ? syncTimeText(row.playedAt)
      : '';
  // 行尾缓存标签统一用紧凑图标，不再占一整段文字。多选 / 排序模式
  // 不渲染 ⋮（见 CollectionTrackRow）。
  final cached = switch (row) {
    LocalSongCollectionRow(:final song) when song.isCached => true,
    _ => false,
  };
  final versionCount = data.smartVersionCounts[row.key] ?? 0;
  final versionTrailing = versionCount <= 1
      ? null
      : M3EButton.text(
          key: ValueKey('smartVersions-${row.key}'),
          onPressed: () => data.onToggleSmartVersions(row),
          child: Text(l10n.duplicateVersions(versionCount)),
        );
  final cachedTrailing =
      versionTrailing ??
      (!cached
          ? null
          : Icon(
              Icons.download_done_rounded,
              size: 16,
              semanticLabel: l10n.localSongsCachedTag,
            ));
  return RowActionsBuilder(
    // Sliver itemBuilder 里不能直接 select：动作构造放进独立 build。
    actions: (rowContext) => (data.reorderActive || data.selecting)
        ? const <RowAction>[]
        : data.rowActionsFor(rowContext, row),
    builder: (rowContext, actions) => CollectionTrackRow(
      row: TrackRowModel(
        title: row.title,
        artist: switch (row) {
          LocalSongCollectionRow(:final song) when song.isMissing =>
            row.artist.isEmpty
                ? l10n.localFileMissing
                : '${row.artist} · ${l10n.localFileMissing}',
          // 宽屏表格把播放时间放回独立列；窄屏双行仍塞进副标题，信息不丢。
          HistoryCollectionRow() when table => row.artist,
          HistoryCollectionRow() =>
            row.artist.isEmpty ? playedAtText : '${row.artist} · $playedAtText',
          _ => row.artist,
        },
        coverUrl: row.artworkUrl,
        album: row.album,
        // 播放时间 = 毫秒时间戳的紧凑文案（与同步日志同一格式）；只有
        // 历史表格档渲染这一列，其余合集 / 双行档不读。
        time: playedAtText,
        durationMs: row.durationMs,
        // 收藏键与播放 TrackId 同源（`sourceKey:songId`）；本地下载副本用
        // local 源键，缓存行 / 历史行保留原曲键。
        trackId: TrackId(row.favoriteKey.sourceKey, row.favoriteKey.songId),
        selected: data.isSelected(row.key),
      ),
      surface: rowSurface,
      trailing: data.reorderActive
          ? Icon(
              Icons.drag_handle_rounded,
              color: Theme.of(rowContext).colorScheme.onSurfaceVariant,
            )
          : cachedTrailing,
      position: calculateCardPosition(index, data.rows.length),
      onTap: data.reorderActive || data.isMissingRow(row)
          ? null
          : () => data.onRowTap(index),
      onTapWithModifiers: (data.reorderActive || !isDesktopPlatform())
          ? null
          : (ctrl, shift) =>
                data.onRowTapWithModifiers(index, ctrl: ctrl, shift: shift),
      onLongPress: data.reorderActive
          ? null
          : () => data.onRowLongPress(row.key),
      // 多选时长按 = 选中锚点到这一行的区间；读屏通过自定义动作拿到同一
      // 语义（普通长按进入多选时不给这个动作，避免两种含义混在一起）。
      longPressSemanticLabel: data.selecting ? l10n.selectionRangeToHere : null,
      actions: actions.isEmpty ? null : actions,
    ),
  );
}

/// 页面级空态：在可用高度里居中（Center），外边距 24。
Widget buildFavoritesEmptyState(BuildContext context, FavoritesBodyData data) {
  final l10n = data.l10n;
  final view = data.view;
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: EmptyState(
        icon: view.isSmartList
            ? Icons.auto_awesome_rounded
            : view.isHistory
            ? Icons.history_rounded
            : view.isLocalSongs
            ? Icons.library_music_rounded
            : view.isFavorites
            ? Icons.favorite_border_rounded
            : Icons.queue_music_rounded,
        message: view.isSmartList
            ? l10n.smartEmpty
            : view.isHistory
            ? l10n.historyEmpty
            : view.isLocalSongs
            ? l10n.localSongsEmpty
            : view.isFavorites
            ? l10n.favoritesEmpty
            : l10n.playlistTracksEmpty,
        // 主行动只在「本页就能完成」时给：本地歌曲空态 = 导入入口（标题行
        // 按钮之外的第二入口，同一动作）。收藏 / 历史 / 自建列表空态不给
        // 按钮——收藏要先在别处收藏、历史要先有播放、自建列表要先在别处
        // 加入曲目，页内没有对应动作可挂。
        action: view.isLocalSongs
            ? M3EButton.icon(
                style: M3EButtonStyle.tonal,
                icon: const Icon(Icons.audio_file_rounded),
                label: Text(l10n.libraryImportLocalSongs),
                onPressed: data.onImportLocal,
              )
            : null,
      ),
    ),
  );
}

/// 资料库读取失败：给出错误 + 重试，而不是把失败伪装成空资料库。
Widget buildFavoritesReadFailed(
  BuildContext context, {
  required AppLocalizations l10n,
  required VoidCallback onRetry,
}) {
  return Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.libraryLoadFailed, style: context.typeScale.bodyLarge),
        const SizedBox(height: 12),
        M3EButton.filled(onPressed: onRetry, child: Text(l10n.retryButton)),
      ],
    ),
  );
}

/// 曲库分组的复用缓存：索引实例 / 模式 / 语言不变时直接复用。
///
/// `LocalLibraryProvider` 的索引是不可变快照（重建时换新实例），因此
/// 引用相等就足以判断分组是否过期。
class FavoritesBrowseGroupsCache {
  LibraryBrowseIndex? _index;
  CollectionMode? _mode;
  String? _locale;
  List<LibraryBrowseGroup> _groups = const [];

  List<LibraryBrowseGroup> groupsFor(
    LibraryBrowseIndex index,
    CollectionMode mode,
    AppLocalizations l10n,
  ) {
    if (identical(_index, index) &&
        _mode == mode &&
        _locale == l10n.localeName) {
      return _groups;
    }
    final groups = mode == CollectionMode.albums
        ? [
            for (final album in index.albums)
              LibraryBrowseGroup(
                key: album.sortKey,
                title: album.album.isEmpty ? l10n.unknownAlbum : album.album,
                subtitle: album.primaryArtist,
                coverUrl: _firstCover(album.tracks),
                tracks: album.tracks,
              ),
          ]
        : [
            for (final artist in index.artists)
              LibraryBrowseGroup(
                key: artist.sortKey,
                title: artist.artist.isEmpty
                    ? l10n.unknownArtist
                    : artist.artist,
                subtitle: '',
                icon: Icons.person_rounded,
                tracks: artist.tracks,
              ),
          ];
    _index = index;
    _mode = mode;
    _locale = l10n.localeName;
    return _groups = groups;
  }

  static String? _firstCover(List<BrowseTrack> tracks) {
    for (final track in tracks) {
      final url = track.coverUrl;
      if (url != null && url.isNotEmpty) return url;
    }
    return null;
  }
}

/// 曲库浏览正文的接线输入：页面只给数据与端口，点播 / 加入曲库 / 换源 /
/// 刷新本地的编排留在本文件，避免页面为五条回调再堆一段。
class FavoritesBrowseData {
  const FavoritesBrowseData({
    required this.l10n,
    required this.query,
    required this.groupsCache,
    required this.shuffleRandom,
    required this.actions,
    required this.downloadRecords,
    required this.lyrics,
    required this.library,
    required this.isActive,
  });

  final AppLocalizations l10n;
  final String query;
  final FavoritesBrowseGroupsCache groupsCache;
  final math.Random? shuffleRandom;
  final CollectionActions actions;
  final DownloadRecords? downloadRecords;
  final LyricsProvider lyrics;
  final LibraryProvider library;
  final bool Function() isActive;
}

/// 曲库浏览分支（含搜索词与缓存索引状态的接线）。
Widget buildFavoritesBrowseTab(BuildContext context, FavoritesBrowseData data) {
  final l10n = data.l10n;
  return buildFavoritesLibraryBrowse(
    context,
    l10n: l10n,
    query: data.query,
    groupsCache: data.groupsCache,
    onPlay: (group, tracks, {bool shuffle = false}) =>
        playFavoritesBrowseTracks(
          context: context,
          tracks: tracks,
          contextName: group.subtitle.isEmpty
              ? group.title
              : '${group.title} · ${group.subtitle}',
          random: data.shuffleRandom,
          shuffle: shuffle,
        ),
    onPlayTrack: (track) => playFavoritesBrowseTracks(
      context: context,
      tracks: [track],
      contextName: track.title,
      random: data.shuffleRandom,
    ),
    onAdd: (tracks) =>
        addFavoritesBrowseToLibrary(context: context, tracks: tracks),
    onToggleFavorite: (track) async {
      await data.actions.toggleFavorite([
        TrackCollectionRow(track.toPlaylistTrack(addedAt: 0)),
      ]);
    },
    onRefreshLocal: (track) => refreshFavoritesBrowseLocal(
      context: context,
      l10n: l10n,
      record: findFavoritesLocalRecord(data.downloadRecords, track),
      isActive: data.isActive,
    ),
    onSwap: (track) => swapFavoritesBrowseTrack(
      context: context,
      track: track,
      lyrics: data.lyrics,
    ),
    isFavorite: (track) =>
        data.library.isFavorite(track.sourceKey, track.songId),
    canRefreshLocal: (track) =>
        findFavoritesLocalRecord(data.downloadRecords, track) != null,
  );
}

/// 曲库：只在这里出现专辑 / 歌手切换；搜索走页面标题行的搜索态。
///
/// 模式 / 索引订阅是本分支自己的 UI 依赖（只在浏览曲库时建立），因此留在
/// 这里而不是让整个收藏页常驻订阅。
Widget buildFavoritesLibraryBrowse(
  BuildContext context, {
  required AppLocalizations l10n,
  required String query,
  required FavoritesBrowseGroupsCache groupsCache,
  required Future<void> Function(
    LibraryBrowseGroup group,
    List<BrowseTrack> tracks, {
    bool shuffle,
  })
  onPlay,
  required Future<void> Function(BrowseTrack track) onPlayTrack,
  required Future<void> Function(List<BrowseTrack> tracks) onAdd,
  required Future<void> Function(BrowseTrack track) onToggleFavorite,
  required Future<void> Function(BrowseTrack track) onRefreshLocal,
  required Future<void> Function(BrowseTrack track) onSwap,
  required bool Function(BrowseTrack track) isFavorite,
  required bool Function(BrowseTrack track) canRefreshLocal,
}) {
  final mode =
      context.watch<CollectionModeStore?>()?.mode ?? CollectionMode.albums;
  final index = context.select<LocalLibraryProvider?, LibraryBrowseIndex?>(
    (provider) => provider?.snapshot?.index,
  );
  if (index == null) {
    return const Center(child: M3ELoadingIndicator());
  }
  final horizontalPadding = context
      .layoutType(ResponsivePageType.browse)
      .horizontalPadding;
  final groups = groupsCache.groupsFor(index, mode, l10n);
  final twoPane = libraryBrowseUsesSplitLayout(
    AdaptiveLayoutScope.of(context).sizeClass,
  );
  return Column(
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(
          horizontalPadding,
          0,
          horizontalPadding,
          8,
        ),
        child: CollectionModeSwitch(
          mode: mode,
          onChanged: (next) {
            unawaited(context.read<CollectionModeStore?>()?.setMode(next));
          },
        ),
      ),
      Expanded(
        child: LibraryBrowseView(
          groups: groups,
          modeName: mode.name,
          query: query,
          emptyTitle: l10n.browseEmptyTitle,
          emptyBody: l10n.browseEmptyBody,
          searchEmpty: l10n.browseSearchEmpty,
          selectHint: l10n.browseSelectHint,
          resetSignature: '${mode.name}|$query',
          twoPane: twoPane,
          isFavorite: isFavorite,
          onPlay: onPlay,
          onPlayTrack: onPlayTrack,
          onAdd: onAdd,
          onToggleFavorite: onToggleFavorite,
          canRefreshLocal: canRefreshLocal,
          onRefreshLocal: onRefreshLocal,
          onSwap: onSwap,
        ),
      ),
    ],
  );
}

/// 合集正文（智能列表展开 / 表格列 / 行点击与批量动作接线）。
///
/// 页面只给 ViewModel、当前合集与滚动控制器；行回调与定位结果都从这里
/// 组装，避免页面为了一个 `buildFavoritesCollectionBody` 再铺三十行。
Widget buildFavoritesCollectionTab(
  BuildContext context, {
  required AppLocalizations l10n,
  required FavoritesViewModel viewModel,
  required CollectionView view,
  required bool reorderActive,
  required bool selecting,
  required String query,
  required ScrollController controller,
  required CollectionActions actions,
  required bool Function() isActive,
  required void Function(
    AppLocalizations l10n,
    CollectionView view,
    List<CollectionRow> rows,
    TrackRowSurface surface,
  )
  onRowsReady,
}) {
  final rows = view.isSmartList
      ? viewModel.displayRows(view: view, query: query)
      : view.visibleRows;
  return buildFavoritesCollectionBody(
    context,
    l10n: l10n,
    view: view,
    rows: rows,
    reorderActive: reorderActive,
    selecting: selecting,
    controller: controller,
    smartVersionCounts: viewModel.smartVersionCounts,
    isSelected: viewModel.isSelected,
    isMissingRow: (row) =>
        view.isSmartList &&
        view.identity.smartListId == SmartListIds.missingFiles &&
        row is LocalSongCollectionRow &&
        row.song.isMissing,
    onToggleSmartVersions: viewModel.toggleSmartVersions,
    onRowTap: (index) {
      final row = view.visibleRows[index];
      if (viewModel.handleRowTap(row.key, view)) return;
      unawaited(playFavoritesView(actions: actions, view: view, index: index));
    },
    onRowTapWithModifiers: (index, {required ctrl, required shift}) {
      final row = view.visibleRows[index];
      if (viewModel.handleRowTap(row.key, view, ctrl: ctrl, shift: shift)) {
        return;
      }
      unawaited(playFavoritesView(actions: actions, view: view, index: index));
    },
    onRowLongPress: (key) {
      if (viewModel.selecting && viewModel.selectionAnchorKey != null) {
        viewModel.selectRangeTo(view, key);
        return;
      }
      viewModel.selectRow(key);
    },
    onReorder: (from, to) => reorderFavoritesTracks(
      actions: actions,
      view: view,
      from: from,
      to: to,
      reportMutation: (outcome) {
        if (outcome.isFailure && context.mounted) {
          M3ESnackbar.show(context, message: l10n.operationFailed);
        }
      },
    ),
    rowActionsFor: (rowContext, row) => buildFavoritesRowActions(
      context: rowContext,
      l10n: l10n,
      session: viewModel.session,
      view: view,
      row: row,
      actions: actions,
      isActive: isActive,
    ),
    onImportLocal: () => unawaited(importLocalAudioFilesFlow(context)),
    onRowsReady: (rows, surface) => onRowsReady(l10n, view, rows, surface),
  );
}
