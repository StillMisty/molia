/// 收藏页头部数据装配：把 ViewModel / 页面控件与回调收成头部模块要的值。
///
/// 页面只负责在点击时提供流程回调；这里不持有 State，也不订阅服务，只在
/// 当前帧读一次局部 UI 依赖（曲库索引 / 智能列表口径 / 下载能力）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/library.dart';
import '../../domain/models/smart_lists.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_providers.dart';
import '../../providers/local_library_provider.dart';
import '../../providers/collection_presenter.dart';
import '../../providers/collection_session.dart';
import '../../providers/favorites_view_model.dart';
import '../../services/download/download_requests.dart';
import '../../utils/collection_row_query.dart';
import 'favorites_header.dart';

/// 标题行 / 搜索行 / 排序行 / 列表 ⋮ 的流程回调。
class FavoritesHeaderCallbacks {
  const FavoritesHeaderCallbacks({
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

  final VoidCallback onOpenPicker;
  final VoidCallback onPlayShuffled;
  final VoidCallback onOpenSearch;
  final VoidCallback onExitSearch;
  final VoidCallback onQueryChanged;
  final VoidCallback onExitReorder;
  final VoidCallback onEnterReorder;
  final ValueChanged<CollectionTrackSort> onSortChanged;

  /// 「最多播放」口径切换；参数是当前是否按收听时长。
  final void Function(bool byTime) onToggleMostPlayedMetric;

  final VoidCallback onImportLocal;
  final VoidCallback onCheckLocalCache;
  final void Function(PlaylistInfo? playlist, List<PlaylistInfo> playlists)
  onEditDetails;
  final void Function(PlaylistInfo? playlist) onChangeCover;
  final void Function(PlaylistInfo? playlist, CollectionView view) onExport;
  final void Function(CollectionView view) onDownloadPlaylist;
  final VoidCallback onClearHistory;
}

/// 多选栏的流程回调 + 两个由选中行推导的展示谓词。
class FavoritesSelectionCallbacks {
  const FavoritesSelectionCallbacks({
    required this.isAllFavorited,
    required this.hasDownloadable,
    required this.onCopyToPlaylist,
    required this.onRemoveFromPlaylist,
    required this.onDeleteHistory,
    required this.onDeleteLocalSongs,
    required this.onToggleFavorite,
    required this.onDownloadSelected,
  });

  final bool Function(List<CollectionRow> rows) isAllFavorited;
  final bool Function(List<CollectionRow> rows) hasDownloadable;
  final VoidCallback onCopyToPlaylist;
  final VoidCallback onRemoveFromPlaylist;
  final VoidCallback onDeleteHistory;
  final VoidCallback onDeleteLocalSongs;
  final VoidCallback onToggleFavorite;
  final VoidCallback onDownloadSelected;
}

/// 标题行 / 搜索行 / 调整顺序行需要的值 + 回调。
FavoritesHeaderData buildFavoritesHeaderData({
  required BuildContext context,
  required WidgetRef ref,
  required AppLocalizations l10n,
  required FavoritesViewModel viewModel,
  required TextEditingController searchController,
  required FocusNode searchFocus,
  required CollectionView view,
  required List<PlaylistInfo> playlists,
  required int? favoritesId,
  required CollectionFrame frame,
  required bool reorderActive,
  required FavoritesHeaderCallbacks callbacks,
}) {
  PlaylistInfo? currentPlaylist;
  for (final playlist in playlists) {
    if (playlist.id == view.playlistId) {
      currentPlaylist = playlist;
      break;
    }
  }
  final libraryIndex = view.isLibraryBrowse
      ? ref.watch(
          localLibraryProvider.select((provider) => provider.snapshot?.index),
        )
      : null;
  final byTime = view.isSmartList
      ? ref.watch(
          localLibraryProvider.select(
            (provider) =>
                provider.mostPlayedMetric == SmartListMetric.listeningTime,
          ),
        )
      : false;
  final DownloadRequests? requests = ref.read(
    downloadRequestsControllerProvider,
  );
  return FavoritesHeaderData(
    l10n: l10n,
    view: view,
    currentPlaylist: currentPlaylist,
    searching: viewModel.state.searching,
    reorderActive: reorderActive,
    sort: viewModel.state.sort,
    libraryIndex: libraryIndex,
    mostPlayedByTime: byTime,
    canDownloadPlaylist: requests != null,
    searchController: searchController,
    searchFocus: searchFocus,
    onOpenPicker: callbacks.onOpenPicker,
    onPlayShuffled: callbacks.onPlayShuffled,
    onOpenSearch: callbacks.onOpenSearch,
    onExitSearch: callbacks.onExitSearch,
    onQueryChanged: callbacks.onQueryChanged,
    onExitReorder: callbacks.onExitReorder,
    onEnterReorder: callbacks.onEnterReorder,
    onSortChanged: callbacks.onSortChanged,
    onToggleMostPlayedMetric: () => callbacks.onToggleMostPlayedMetric(byTime),
    onImportLocal: callbacks.onImportLocal,
    onCheckLocalCache: callbacks.onCheckLocalCache,
    onEditDetails: () => callbacks.onEditDetails(currentPlaylist, playlists),
    onChangeCover: () => callbacks.onChangeCover(currentPlaylist),
    onExport: () => callbacks.onExport(currentPlaylist, view),
    onDownloadPlaylist: () => callbacks.onDownloadPlaylist(view),
    onClearHistory: callbacks.onClearHistory,
  );
}

/// 多选栏需要的值 + 回调。
FavoritesSelectionHeaderData buildFavoritesSelectionHeaderData({
  required AppLocalizations l10n,
  required FavoritesViewModel viewModel,
  required CollectionView view,
  required FavoritesSelectionCallbacks callbacks,
}) {
  final selectedRows = viewModel.selectedRows(view);
  return FavoritesSelectionHeaderData(
    l10n: l10n,
    view: view,
    selectedCount: viewModel.state.selectedCount,
    allSelected: viewModel.allSelected(view) == true,
    allFavorited:
        selectedRows.isNotEmpty && callbacks.isAllFavorited(selectedRows),
    hasDownloadable:
        selectedRows.isNotEmpty && callbacks.hasDownloadable(selectedRows),
    onClose: viewModel.clearSelection,
    onSelectAll: () => viewModel.selectAllVisible(view),
    onCopyToPlaylist: callbacks.onCopyToPlaylist,
    onRemoveFromPlaylist: callbacks.onRemoveFromPlaylist,
    onDeleteHistory: callbacks.onDeleteHistory,
    onDeleteLocalSongs: callbacks.onDeleteLocalSongs,
    onToggleFavorite: callbacks.onToggleFavorite,
    onDownloadSelected: callbacks.onDownloadSelected,
  );
}
