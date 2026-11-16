import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../pages/downloads_and_cache_page.dart';
import '../../pages/music_folders_page.dart';
import 'settings_section_availability.dart';
import 'settings_tiles.dart';

/// 设置首屏「曲库与存储」卡：本地文件夹与下载 / 缓存。
///
/// 下载设置、下载管理与缓存管理合并为一个子页，首屏不再为同一类事情
/// 付出三行；加入收藏与列表的位置收进「高级设置」。
class LibraryStorageSection extends StatelessWidget {
  const LibraryStorageSection({super.key, required this.availability});

  final SettingsSectionAvailability availability;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SettingsSectionCard(
      title: l10n.settingsLibraryStorageTitle,
      children: [
        // 音乐文件夹：扫描目录、进度 / 摘要与手动重扫（iOS 不展示）。
        if (availability.musicFoldersRowVisible)
          SettingsNavTile(
            key: const Key('settingsMusicFoldersItem'),
            icon: Icons.folder_copy_rounded,
            title: l10n.musicFoldersTitle,
            subtitle: l10n.musicFoldersSubtitle,
            onTap: () => openSettingsSubPage(context, const MusicFoldersPage()),
          ),
        // 下载与缓存：保存位置 / 任务入口 / 缓存策略与清理。
        SettingsNavTile(
          key: const Key('settingsDownloadsAndCacheItem'),
          icon: Icons.download_for_offline_rounded,
          title: l10n.settingsDownloadsAndCacheTitle,
          subtitle: l10n.settingsDownloadsAndCacheSubtitle,
          onTap: () =>
              openSettingsSubPage(context, const DownloadsAndCachePage()),
        ),
      ],
    );
  }
}
