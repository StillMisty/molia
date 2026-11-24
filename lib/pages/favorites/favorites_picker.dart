/// 收藏页合集切换弹层：打开弹层、分组默认收起、分组重命名 / 删除。
///
/// 条目构建（顺序 / 计数 / 选中态 / 智能列表）在 [FavoritesViewModel]；
/// 弹层本身（[showCollectionPicker]）不认识收藏页，这里只做编排与结果回传。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/library.dart';
import '../../domain/models/library_browse.dart';
import '../../domain/models/playlist_folders.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_providers.dart';
import '../../providers/collection_presenter.dart';
import '../../providers/collection_session.dart';
import '../../providers/favorites_view_model.dart';
import '../../providers/library_outcome.dart';
import '../../providers/library_provider.dart';
import '../../providers/local_library_provider.dart';
import '../../services/download/download_records.dart';
import '../../widgets/collection_picker.dart';

/// 打开合集切换弹层：点行切换、新建/重命名/删除、导入收藏、
/// 行尾把手拖动排序。
///
/// 本地歌曲计数含缓存行：弹层打开前先把缓存行重算到当前输入，否则刚启动
/// （还没进过本地歌曲合集）时计数会漏掉缓存行、与列表行数对不上。
/// 重算只读传入的 [frame]；签名未变时是零等待，只有输入变过才等一次音频
/// 缓存目录列举。
Future<CollectionPickerOutcome?> showFavoritesCollectionPicker({
  required BuildContext context,
  required AppLocalizations l10n,
  required CollectionFrame frame,
  required List<PlaylistInfo> playlists,
  required int? favoritesId,
  required int selected,
  required int historyCount,
  required LibraryProvider provider,
  required DownloadRecords? records,
  required FavoritesViewModel viewModel,
  required LibraryBrowseIndex? browseIndex,
  required Map<String, List<CollectionRow>> smartRows,
  required Future<void> Function(CollectionFrame frame) ensureLocalSongsReady,
  required void Function(List<String> keys) onOrderChanged,
  required bool Function() isActive,
}) async {
  await ensureLocalSongsReady(frame);
  if (!context.mounted || !isActive()) return null;
  final folderCollapse = viewModel.folderCollapse;
  // 首次进入：分组默认收起，只展开当前列表所在分组。用户手动改过折叠
  // 状态后由 controller 记住，不再套默认值。
  if (hasNamedPlaylistFolders(playlists)) {
    final folders = <String>{
      for (final playlist in playlists)
        if (normalizePlaylistFolderName(playlist.folder).isNotEmpty)
          normalizePlaylistFolderName(playlist.folder),
    };
    String? selectedFolder;
    for (final playlist in playlists) {
      if (playlist.id == selected) {
        final folder = normalizePlaylistFolderName(playlist.folder);
        if (folder.isNotEmpty) selectedFolder = folder;
        break;
      }
    }
    folderCollapse.applyDefaults(folders, expanded: selectedFolder);
  }
  return showCollectionPicker(
    context,
    title: l10n.favoritesSwitchTitle,
    entries: viewModel.collectionEntries(
      l10n: l10n,
      playlists: playlists,
      favoritesId: favoritesId,
      selected: selected,
      historyCount: historyCount,
      localSongsSupported: records?.supported ?? false,
      browseIndex: browseIndex,
    ),
    smartEntries: viewModel.smartPickerEntries(
      l10n: l10n,
      selected: selected,
      smartRows: smartRows,
    ),
    onOrderChanged: onOrderChanged,
    onDelete: provider.deletePlaylist,
    onCreate: provider.createPlaylist,
    onRename: provider.renamePlaylist,
    folderCollapse: folderCollapse,
    onFolderRename: (from, to) async {
      try {
        await provider.renamePlaylistFolder(from, to);
        return const LibraryMutationOutcome.applied();
      } catch (e) {
        debugPrint('[Favorites] 重命名分组失败: $e');
        return LibraryMutationOutcome.failed(e);
      }
    },
    onFolderDelete: (folder) async {
      try {
        await provider.deletePlaylistFolder(folder);
        return const LibraryMutationOutcome.applied();
      } catch (e) {
        debugPrint('[Favorites] 删除分组失败: $e');
        return LibraryMutationOutcome.failed(e);
      }
    },
  );
}

/// 读取当前 context 的 provider 快照并打开合集弹层（页面只关心结果）。
Future<CollectionPickerOutcome?> openFavoritesCollectionPicker({
  required WidgetRef ref,
  required BuildContext context,
  required AppLocalizations l10n,
  required CollectionFrame frame,
  required List<PlaylistInfo> playlists,
  required int? favoritesId,
  required int selected,
  required FavoritesViewModel viewModel,
  required void Function(List<String> keys) onOrderChanged,
  required bool Function() isActive,
}) {
  final library = ref.read(libraryProvider);
  final provider = ref.read(libraryControllerProvider);
  final DownloadRecords? records = ref.read(downloadRecordsControllerProvider);
  final LocalLibraryState localLibrary = ref.read(localLibraryProvider);
  return showFavoritesCollectionPicker(
    context: context,
    l10n: l10n,
    frame: frame,
    playlists: playlists,
    favoritesId: favoritesId,
    selected: selected,
    historyCount: library.history.length,
    provider: provider,
    records: records,
    viewModel: viewModel,
    browseIndex: localLibrary.snapshot?.index,
    smartRows: localLibrary.smartRows,
    ensureLocalSongsReady: viewModel.session.ensureLocalSongsReady,
    onOrderChanged: onOrderChanged,
    isActive: isActive,
  );
}
