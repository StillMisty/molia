import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../pages/cache_management_page.dart';
import '../../pages/download_settings_page.dart';
import '../../pages/downloads_manage_page.dart';
import '../../pages/music_folders_page.dart';
import '../../services/library/library_add_settings.dart';
import 'library_storage_section_model.dart';
import 'settings_section_availability.dart';
import 'settings_tiles.dart';

/// 设置首屏「曲库与存储」卡：新歌加入位置、本地文件夹与下载 / 缓存。
///
/// 这些行都围绕「歌从哪里来、存在哪里」：加入位置是曲库行为，文件夹是本地
/// 导入，下载与缓存是占用治理。文件夹、下载与缓存是设备本地键，卡底一句
/// 说明；加入位置跟人走，不在此列。
///
/// 行集合、值与写入由 [LibraryStorageSectionModel] 声明，本类只负责把行映射成
/// 控件；远端值应用后的重载仍由资料库栈挂到该服务上（模型只转发 `reload`）。
class LibraryStorageSection extends StatelessWidget {
  const LibraryStorageSection({super.key, required this.availability});

  final SettingsSectionAvailability availability;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final model = LibraryStorageSectionModel(
      addSettings: availability.libraryAdd,
      platform: availability.platform,
    );
    return SettingsSectionCard(
      title: l10n.settingsLibraryStorageTitle,
      footer: SettingsSectionHint(
        text: l10n.settingsLibraryStorageDeviceLocalHint,
      ),
      children: [
        for (final row in model.visibleRows)
          switch (row) {
            LibraryStorageRow.addPosition => _addPositionRow(
              context,
              l10n,
              model,
            ),
            LibraryStorageRow.musicFolders => SettingsNavTile(
              key: const Key('settingsMusicFoldersItem'),
              icon: Icons.folder_copy_rounded,
              title: l10n.musicFoldersTitle,
              subtitle: l10n.musicFoldersSubtitle,
              onTap: () =>
                  openSettingsSubPage(context, const MusicFoldersPage()),
            ),
            LibraryStorageRow.downloadSettings => SettingsNavTile(
              key: const Key('settingsDownloadSettingsItem'),
              icon: Icons.download_rounded,
              title: l10n.downloadSettingsTitle,
              subtitle: l10n.downloadSettingsSubtitle,
              onTap: () =>
                  openSettingsSubPage(context, const DownloadSettingsPage()),
            ),
            LibraryStorageRow.downloadsManage => SettingsNavTile(
              key: const Key('settingsDownloadsManageItem'),
              icon: Icons.download_for_offline_rounded,
              title: l10n.downloadsManageTitle,
              subtitle: l10n.downloadsManageSubtitle,
              onTap: () =>
                  openSettingsSubPage(context, const DownloadsManagePage()),
            ),
            LibraryStorageRow.cacheManagement => SettingsNavTile(
              key: const Key('settingsCacheManagementItem'),
              icon: Icons.storage_rounded,
              title: l10n.settingsCacheTitle,
              subtitle: l10n.settingsCacheSubtitle,
              onTap: () =>
                  openSettingsSubPage(context, const CacheManagementPage()),
            ),
          },
      ],
    );
  }

  /// 加入收藏 / 列表的位置：新曲目放开头还是末尾（默认开头）。
  ///
  /// selector 只负责订阅：值统一从模型读，避免卡片里出现第二份读口。
  Widget _addPositionRow(
    BuildContext context,
    AppLocalizations l10n,
    LibraryStorageSectionModel model,
  ) {
    return Selector<LibraryAddSettings, LibraryAddPosition>(
      selector: (context, settings) => model.addPosition,
      builder: (context, position, _) => SettingsChoiceRow<LibraryAddPosition>(
        key: const Key('settingsLibraryAddPositionItem'),
        icon: Icons.playlist_add_rounded,
        title: l10n.settingsLibraryAddPosition,
        subtitle: l10n.settingsLibraryAddPositionSubtitle,
        value: position,
        options: [
          (LibraryAddPosition.top, l10n.settingsLibraryAddPositionTop),
          (LibraryAddPosition.bottom, l10n.settingsLibraryAddPositionBottom),
        ],
        onChanged: model.setAddPosition,
      ),
    );
  }
}
