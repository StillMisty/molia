import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../pages/cache_management_page.dart';
import '../../pages/download_settings_page.dart';
import '../../pages/downloads_manage_page.dart';
import '../../pages/music_folders_page.dart';
import '../../services/library/library_add_settings.dart';
import 'settings_tiles.dart';

/// 设置首屏「曲库与存储」卡：新歌加入位置、本地文件夹与下载 / 缓存。
///
/// 这些行都围绕「歌从哪里来、存在哪里」：加入位置是曲库行为，文件夹是本地
/// 导入，下载与缓存是占用治理。文件夹、下载与缓存是设备本地键，卡底一句
/// 说明；加入位置跟人走，不在此列。
class LibraryStorageSection extends StatelessWidget {
  const LibraryStorageSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final libraryAddSettings = context.watch<LibraryAddSettings?>();
    return SettingsSectionCard(
      title: l10n.settingsLibraryStorageTitle,
      footer: SettingsSectionHint(
        text: l10n.settingsLibraryStorageDeviceLocalHint,
      ),
      children: [
        // 加入收藏 / 列表的位置：新曲目放开头还是末尾（默认开头）。
        if (libraryAddSettings != null)
          Selector<LibraryAddSettings, LibraryAddPosition>(
            selector: (context, settings) => settings.position,
            builder: (context, position, _) =>
                SettingsChoiceRow<LibraryAddPosition>(
                  key: const Key('settingsLibraryAddPositionItem'),
                  icon: Icons.playlist_add_rounded,
                  title: l10n.settingsLibraryAddPosition,
                  subtitle: l10n.settingsLibraryAddPositionSubtitle,
                  value: position,
                  options: [
                    (
                      LibraryAddPosition.top,
                      l10n.settingsLibraryAddPositionTop,
                    ),
                    (
                      LibraryAddPosition.bottom,
                      l10n.settingsLibraryAddPositionBottom,
                    ),
                  ],
                  onChanged: libraryAddSettings.setPosition,
                ),
          ),
        // 音乐文件夹：扫描目录、进度 / 摘要与手动重扫（iOS 不展示）。
        if (defaultTargetPlatform != TargetPlatform.iOS)
          SettingsNavTile(
            key: const Key('settingsMusicFoldersItem'),
            icon: Icons.folder_copy_rounded,
            title: l10n.musicFoldersTitle,
            subtitle: l10n.musicFoldersSubtitle,
            onTap: () => openSettingsSubPage(context, const MusicFoldersPage()),
          ),
        // 下载设置：保存位置 / 文件名格式 / 标签嵌入。
        SettingsNavTile(
          key: const Key('settingsDownloadSettingsItem'),
          icon: Icons.download_rounded,
          title: l10n.downloadSettingsTitle,
          subtitle: l10n.downloadSettingsSubtitle,
          onTap: () =>
              openSettingsSubPage(context, const DownloadSettingsPage()),
        ),
        // 下载管理：任务队列 / 批量下载 / 文件维护。
        SettingsNavTile(
          key: const Key('settingsDownloadsManageItem'),
          icon: Icons.download_for_offline_rounded,
          title: l10n.downloadsManageTitle,
          subtitle: l10n.downloadsManageSubtitle,
          onTap: () =>
              openSettingsSubPage(context, const DownloadsManagePage()),
        ),
        // 缓存管理：音频/歌词/封面占用 + 策略 + 单清/全清。
        SettingsNavTile(
          key: const Key('settingsCacheManagementItem'),
          icon: Icons.storage_rounded,
          title: l10n.settingsCacheTitle,
          subtitle: l10n.settingsCacheSubtitle,
          onTap: () =>
              openSettingsSubPage(context, const CacheManagementPage()),
        ),
      ],
    );
  }
}
