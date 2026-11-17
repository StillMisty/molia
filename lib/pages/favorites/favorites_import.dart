/// 收藏页「导入收藏」：.lxmc 文件 / 平台歌单文件 / 平台歌单链接。
///
/// 流程与类型化结果仍在 [CollectionIoCommands]；本文件只负责弹层选择、
/// 文案映射与「导入成功后进入新列表」。依赖（l10n、命令工厂、选集回调）
/// 全部显式传入，方便页面与后续 ViewModel 复用。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/collection_io_commands.dart';
import '../../providers/discover_provider.dart';
import '../../providers/sync_provider.dart';
import '../../services/save_as.dart';
import '../../services/download/download_requests.dart';
import '../../theme/m3e_context.dart';
import '../../widgets/link_import_dialog.dart';
import '../../widgets/lxmc_import.dart' show importLxmcFavoritesFlow;

/// 页面组装好的合集 I/O 命令工厂（端口按每次动作的 context 现取）。
typedef FavoritesIoCommandsFactory = CollectionIoCommands Function({
  DiscoverProvider? discover,
  DownloadRequests? requests,
  SyncProvider? sync,
  SaveAs? saveAs,
});

/// 合集弹层的「导入收藏」：.lxmc 文件 / 平台歌单文件 / 歌单链接。
Future<void> importFavoritesCollection({
  required BuildContext context,
  required AppLocalizations l10n,
  required DiscoverProvider? discover,
  required bool Function() isActive,
  required void Function(int playlistId) selectCollection,
  required FavoritesIoCommandsFactory ioCommands,
}) async {
  final choices = <({String value, IconData icon, String label})>[
    (
      value: 'file',
      icon: Icons.folder_open_rounded,
      label: l10n.playlistImportFromFile,
    ),
    (
      value: 'playlistFile',
      icon: Icons.playlist_add_rounded,
      label: l10n.playlistImport,
    ),
    if (discover != null)
      (
        value: 'link',
        icon: Icons.link_rounded,
        label: l10n.playlistImportFromLink,
      ),
  ];
  final choice = await M3EBottomSheet.show<String>(
    context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: Text(
              l10n.libraryImportFavorites,
              style: sheetContext.typeScale.titleMedium,
            ),
          ),
          for (final item in choices)
            M3EListItem(
              leading: Icon(item.icon),
              headline: item.label,
              onTap: () => Navigator.of(sheetContext).pop(item.value),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted || !isActive()) return;
  if (choice == 'file') {
    final result = await importLxmcFavoritesFlow(context);
    // 导入成功后直接进入该列表（与链接导入同语义）。
    if (!context.mounted || !isActive() || result == null) return;
    selectCollection(result.playlistId);
    return;
  }
  if (choice == 'playlistFile') {
    await importFavoritesPlaylistFile(
      context: context,
      l10n: l10n,
      isActive: isActive,
      selectCollection: selectCollection,
      ioCommands: ioCommands,
    );
    return;
  }
  if (discover != null) {
    await importFavoritesFromLink(
      context: context,
      l10n: l10n,
      discover: discover,
      isActive: isActive,
      selectCollection: selectCollection,
      ioCommands: ioCommands,
    );
  }
}

/// M3U / M3U8 / PLS 导入：解析 → 本机解析 → 复核 → 才创建列表。
///
/// 流程与结果类型在 [CollectionIoCommands]，这里只留提示 / 选中新列表。
Future<void> importFavoritesPlaylistFile({
  required BuildContext context,
  required AppLocalizations l10n,
  required bool Function() isActive,
  required void Function(int playlistId) selectCollection,
  required FavoritesIoCommandsFactory ioCommands,
}) async {
  final outcome = await ioCommands().importPlaylistFile(
    dialogTitle: l10n.playlistImport,
    isActive: isActive,
  );
  if (!context.mounted || !isActive()) return;
  switch (outcome) {
    case CollectionPlaylistImportDone(
      :final playlistId,
      :final added,
      :final skipped,
    ):
      selectCollection(playlistId);
      M3ESnackbar.show(
        context,
        message: l10n.playlistImportDone(added, skipped),
      );
    case CollectionPlaylistImportEmpty():
      M3ESnackbar.show(context, message: l10n.playlistImportEmpty);
    case CollectionPlaylistImportFailed():
      M3ESnackbar.show(context, message: l10n.playlistImportFailed);
    case CollectionPlaylistImportCancelled():
      break;
  }
}

/// 内置平台歌单 / 收藏夹链接导入：选平台 + 粘贴链接/ID → 拉取并存入本地列表。
Future<void> importFavoritesFromLink({
  required BuildContext context,
  required AppLocalizations l10n,
  required DiscoverProvider discover,
  required bool Function() isActive,
  required void Function(int playlistId) selectCollection,
  required FavoritesIoCommandsFactory ioCommands,
}) async {
  final channels = [
    for (final key in discover.sourceKeys)
      (key: key, name: discover.sourceDisplayName(key)),
  ];
  final input = await showLinkImportDialog(context, channels: channels);
  if (input == null || !context.mounted || !isActive()) return;
  final outcome = await ioCommands(discover: discover).importFromLink(
    sourceKey: input.sourceKey,
    rawId: input.rawId,
    fallbackName: l10n.playlistImportedName,
  );
  if (!context.mounted || !isActive()) return;
  switch (outcome) {
    case CollectionLinkImportDone(:final playlistId, :final added):
      selectCollection(playlistId);
      M3ESnackbar.show(context, message: l10n.libraryImportSuccess(added));
    case CollectionLinkImportEmpty():
      M3ESnackbar.show(context, message: l10n.playlistImportEmpty);
    case CollectionLinkImportAlreadyContains():
      M3ESnackbar.show(context, message: l10n.playlistAlreadyContains);
    case CollectionLinkImportFailed():
      M3ESnackbar.show(context, message: l10n.discoverLoadFailed);
  }
}
