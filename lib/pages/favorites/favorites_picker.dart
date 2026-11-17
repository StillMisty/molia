/// 收藏页合集切换弹层：条目构建、分组默认收起、分组重命名 / 删除。
///
/// 弹层本身（[showCollectionPicker]）不认识收藏页；这里只把页面的值
/// （列表清单、顺序、本地歌曲计数、曲库摘要）投影成条目，并把用户结果
/// 原样交回页面处理。
library;

import 'package:material_ui/material_ui.dart';

import '../../domain/models/library.dart';
import '../../domain/models/library_browse.dart';
import '../../domain/models/playlist_folders.dart';
import '../../domain/models/smart_lists.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/collection_presenter.dart';
import '../../providers/collection_session.dart';
import '../../providers/library_collections.dart';
import '../../providers/library_outcome.dart';
import '../../providers/library_provider.dart';
import '../../services/download/download_records.dart';
import '../../services/library/playlist_folder_prefs.dart';
import '../../widgets/collection_picker.dart';
import 'favorites_models.dart';

/// 合集条目：收藏 / 播放历史 / 本地歌曲 / 曲库 / 各列表。按持久化顺序
/// 排列，未记录的新列表按自然顺序（收藏 → 历史 → 本地歌曲 → 列表）追加在
/// 末尾；下载能力不可用时不出现本地歌曲。
///
/// 合集弹层按这一份解析出顺序 / 图标 / 选中态。
List<CollectionPickerEntry> buildCollectionPickerEntries({
  required AppLocalizations l10n,
  required LibraryProvider provider,
  required List<PlaylistInfo> playlists,
  required int? favoritesId,
  required int selected,
  required DownloadRecords? records,
  required int localSongsCount,
  required List<String> collectionOrder,
  required LibraryBrowseIndex? browseIndex,
  required PlaylistFolderCollapseController folderCollapse,
}) {
  var favoritesCount = 0;
  for (final playlist in playlists) {
    if (playlist.id == favoritesId) {
      favoritesCount = playlist.trackCount;
      break;
    }
  }
  final showLocalSongs = records?.supported ?? false;
  // 固定入口顺序恒定，不参与拖动排序：收藏 → 历史 → 本地歌曲 → 曲库。
  final pinned = <CollectionPickerEntry>[
    CollectionPickerEntry(
      key: LibraryCollections.favoritesOrderKey,
      id: LibraryCollections.favoritesSentinel,
      name: l10n.favoritesPlaylistName,
      icon: Icons.favorite_rounded,
      trackCount: favoritesCount,
      selected: selected == LibraryCollections.favoritesSentinel,
      pinned: true,
    ),
    CollectionPickerEntry(
      key: LibraryCollections.historyOrderKey,
      id: LibraryCollections.historySentinel,
      name: l10n.libraryHistory,
      icon: Icons.history_rounded,
      trackCount: provider.history.length,
      selected: selected == LibraryCollections.historySentinel,
      pinned: true,
    ),
    if (showLocalSongs)
      CollectionPickerEntry(
        key: LibraryCollections.downloadsOrderKey,
        id: LibraryCollections.downloadsSentinel,
        name: l10n.libraryLocalSongs,
        icon: Icons.library_music_rounded,
        // 计数与列表行数同源：下载 / 导入记录 + 缓存完成索引里命中缓存的
        // 行（弹层打开前会先把缓存行重算到当前输入）。
        trackCount: localSongsCount,
        selected: selected == LibraryCollections.downloadsSentinel,
        pinned: true,
      ),
    CollectionPickerEntry(
      key: LibraryCollections.libraryBrowseOrderKey,
      id: LibraryCollections.libraryBrowseSentinel,
      name: l10n.libraryBrowseTitle,
      icon: Icons.library_books_rounded,
      trackCount: 0,
      selected: selected == LibraryCollections.libraryBrowseSentinel,
      pinned: true,
      supportingText: libraryBrowseSummary(l10n, browseIndex),
    ),
  ];

  // 自建列表：只有这一段参与拖动排序；分组投影保持命名分组在前、
  // 未分组在后，组内沿用设备本地顺序。
  final natural = <String>[
    for (final playlist in playlists)
      if (playlist.id != favoritesId) 'playlist:${playlist.id}',
  ];
  final orderedKeys = LibraryCollections.applyOrder(natural, collectionOrder);
  final byKey = <String, CollectionPickerEntry>{
    for (final playlist in playlists)
      if (playlist.id != favoritesId)
        'playlist:${playlist.id}': CollectionPickerEntry(
          key: 'playlist:${playlist.id}',
          id: playlist.id,
          name: playlist.name,
          icon: Icons.queue_music_rounded,
          trackCount: playlist.trackCount,
          selected: selected == playlist.id,
          playlistId: playlist.id,
          folder: normalizePlaylistFolderName(playlist.folder),
        ),
  };
  final playlistEntries = <CollectionPickerEntry>[
    for (final key in orderedKeys)
      if (byKey[key] != null) byKey[key]!,
  ];
  if (!hasNamedPlaylistFolders(playlists)) {
    return [...pinned, ...playlistEntries];
  }
  final groups = groupPlaylistsByFolder(
    [
      for (final entry in playlistEntries)
        playlists.firstWhere((item) => item.id == entry.id),
    ],
    excludePlaylistIds: {?favoritesId},
  );
  return [
    ...pinned,
    for (final group in groups)
      if (group.isUngrouped) ...[
        for (final playlist in group.playlists)
          if (byKey['playlist:${playlist.id}'] != null)
            byKey['playlist:${playlist.id}']!,
      ] else ...[
        CollectionPickerEntry(
          key: 'folder:${group.folder}',
          id: LibraryCollections.unset,
          name: group.folder,
          icon: Icons.folder_rounded,
          trackCount: 0,
          selected: false,
          folder: group.folder,
          isFolderHeader: true,
          folderCollapsed: folderCollapse.isCollapsed(group.folder),
        ),
        for (final playlist in group.playlists)
          if (byKey['playlist:${playlist.id}'] != null)
            byKey['playlist:${playlist.id}']!,
      ],
  ];
}

/// 智能列表条目：分组标题 + 各智能列表（计数来自设备本地投影）。
List<CollectionPickerEntry> buildSmartPickerEntries({
  required AppLocalizations l10n,
  required int selected,
  required Map<String, List<CollectionRow>> smartRows,
}) {
  final names = smartListNames(l10n);
  return [
    CollectionPickerEntry(
      key: 'smart:header',
      id: LibraryCollections.unset,
      name: l10n.smartListsSection,
      icon: Icons.auto_awesome_rounded,
      trackCount: 0,
      selected: false,
      isHeader: true,
      isCollapsibleHeader: true,
    ),
    for (final id in SmartListIds.all)
      CollectionPickerEntry(
        key: id,
        id: LibraryCollections.smartSentinelFor(id),
        name: names[id] ?? id,
        icon: smartListIcon(id),
        trackCount: smartRows[id]?.length ?? 0,
        selected: selected == LibraryCollections.smartSentinelFor(id),
        isSmart: true,
      ),
  ];
}

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
  required LibraryProvider provider,
  required DownloadRecords? records,
  required int localSongsCount,
  required List<String> collectionOrder,
  required LibraryBrowseIndex? browseIndex,
  required Map<String, List<CollectionRow>> smartRows,
  required PlaylistFolderCollapseController folderCollapse,
  required Future<void> Function(CollectionFrame frame) ensureLocalSongsReady,
  required void Function(List<String> keys) onOrderChanged,
  required bool Function() isActive,
}) async {
  await ensureLocalSongsReady(frame);
  if (!context.mounted || !isActive()) return null;
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
    entries: buildCollectionPickerEntries(
      l10n: l10n,
      provider: provider,
      playlists: playlists,
      favoritesId: favoritesId,
      selected: selected,
      records: records,
      localSongsCount: localSongsCount,
      collectionOrder: collectionOrder,
      browseIndex: browseIndex,
      folderCollapse: folderCollapse,
    ),
    smartEntries: buildSmartPickerEntries(
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
