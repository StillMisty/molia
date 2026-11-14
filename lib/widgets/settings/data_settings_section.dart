import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../pages/cache_management_page.dart';
import '../../pages/diagnostics_page.dart';
import '../../pages/download_settings_page.dart';
import '../../pages/downloads_manage_page.dart';
import '../../pages/music_folders_page.dart';
import '../../pages/play_statistics_page.dart';
import '../../pages/sync_settings_page.dart';
import '../../providers/sync_provider.dart';
import '../../services/json_backup_picker.dart';
import '../../services/notification_service.dart';
import '../../services/play_statistics_service.dart';
import '../../services/save_as.dart';
import '../../utils/save_as_label.dart';
import '../lxmc_import.dart' show importLxmcFavoritesFlow;
import 'settings_tiles.dart';

/// 设置首屏「数据与存储」卡：缓存、下载、音乐文件夹、统计、导入导出、
/// 同步与问题排查。
///
/// 这里的子页入口与 key 和既有深链、测试保持一致，改动会打断它们。
class DataSettingsSection extends StatelessWidget {
  const DataSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 完整备份只经同步引擎的适配器收集/合并；引擎未挂载（测试）时导出 /
    // 导入都按失败处理（没有可回退的旧数据源）。
    final syncProvider = context.watch<SyncProvider?>();
    final statistics = context.watch<PlayStatisticsService?>();
    return SettingsSectionCard(
      title: l10n.dataManagementTitle,
      children: [
        // 缓存管理：音频/歌词/封面占用 + 策略 + 单清/全清。
        SettingsNavTile(
          key: const Key('settingsCacheManagementItem'),
          icon: Icons.storage_rounded,
          title: l10n.settingsCacheTitle,
          subtitle: l10n.settingsCacheSubtitle,
          onTap: () =>
              openSettingsSubPage(context, const CacheManagementPage()),
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
        // 音乐文件夹：扫描目录、进度 / 摘要与手动重扫（iOS 不展示）。
        if (defaultTargetPlatform != TargetPlatform.iOS)
          SettingsNavTile(
            key: const Key('settingsMusicFoldersItem'),
            icon: Icons.folder_copy_rounded,
            title: l10n.musicFoldersTitle,
            subtitle: l10n.musicFoldersSubtitle,
            onTap: () => openSettingsSubPage(context, const MusicFoldersPage()),
          ),
        // 统计采集开关（关闭 = 停止记录新事件，已有数据保留）。
        if (statistics != null)
          ValueListenableBuilder<bool>(
            valueListenable: statistics.enabledNotifier,
            builder: (context, enabled, _) => SettingsSwitchTile(
              switchKey: const Key('settingsPlayStatisticsSwitch'),
              icon: Icons.query_stats_rounded,
              title: l10n.statsRecordSwitch,
              subtitle: l10n.statsRecordSwitchSubtitle,
              value: enabled,
              onChanged: (value) => unawaited(statistics.setEnabled(value)),
            ),
          ),
        // 听歌统计：事件级采集（本机），播放次数 / 热力图 / 导出。
        SettingsNavTile(
          key: const Key('settingsPlayStatisticsItem'),
          icon: Icons.insights_rounded,
          title: l10n.statsTitle,
          subtitle: l10n.statsSettingsSubtitle,
          onTap: () => openSettingsSubPage(context, const PlayStatisticsPage()),
        ),
        SettingsNavTile(
          icon: Icons.upload_file_rounded,
          title: l10n.exportDataTitle,
          subtitle: l10n.exportDataSubtitle,
          onTap: () => _exportData(context, l10n, syncProvider),
        ),
        SettingsNavTile(
          icon: Icons.download_rounded,
          title: l10n.importDataTitle,
          subtitle: l10n.importDataSubtitle,
          onTap: () => _showImportDialog(context, l10n, syncProvider),
        ),
        SettingsNavTile(
          icon: Icons.favorite_border_rounded,
          title: l10n.libraryImportFavorites,
          subtitle: l10n.libraryImportFavoritesSubtitle,
          onTap: () => importLxmcFavoritesFlow(context),
        ),
        if (syncProvider != null)
          SettingsNavTile(
            key: const Key('settingsSyncItem'),
            icon: Icons.sync_rounded,
            title: l10n.settingsSyncTitle,
            subtitle: l10n.settingsSyncItemSubtitle,
            onTap: () => openSettingsSubPage(context, const SyncSettingsPage()),
          ),
        SettingsNavTile(
          key: const Key('settingsDiagnosticsItem'),
          icon: Icons.support_agent_rounded,
          title: l10n.diagnosticsTitle,
          subtitle: l10n.diagnosticsSubtitle,
          onTap: () => openSettingsSubPage(context, const DiagnosticsPage()),
        ),
      ],
    );
  }

  Future<void> _exportData(
    BuildContext context,
    AppLocalizations l10n,
    SyncProvider? syncProvider,
  ) async {
    final saveAs = Provider.of<SaveAs?>(context, listen: false);
    final notificationService = Provider.of<NotificationService>(
      context,
      listen: false,
    );
    final currentContext = context;

    // 没有同步引擎就没有完整备份的收集面：直接按导出失败提示。
    if (syncProvider == null) {
      notificationService.showErrorSnackBar(l10n.exportFailed);
      return;
    }

    try {
      // 完整备份：默认导出全部类别与凭证，保证换机后的状态一致。
      final json = await syncProvider.commands.backup.exportJson();
      if (saveAs == null) throw StateError('SaveAs 未装配');
      final result = await saveAs.saveBytes(
        fileName: 'molia_backup_${_fileTimestamp()}.json',
        bytes: Uint8List.fromList(utf8.encode(json)),
        mimeType: 'application/json',
        relativeDir: saveAsExportsDirName,
        dialogTitle: l10n.exportDataTitle,
      );
      if (!currentContext.mounted) return;
      _showSaveResult(l10n, notificationService, result);
    } catch (e) {
      if (currentContext.mounted) {
        notificationService.showErrorSnackBar(l10n.exportFailed);
      }
    }
  }

  Future<void> _showImportDialog(
    BuildContext context,
    AppLocalizations l10n,
    SyncProvider? syncProvider,
  ) async {
    final notificationService = Provider.of<NotificationService>(
      context,
      listen: false,
    );
    final navigator = Navigator.of(context, rootNavigator: true);
    final currentContext = context;

    M3EDialog.show<void>(
      currentContext,
      dialog: M3EDialog(
        title: l10n.importDialogTitle,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: Text(l10n.importDialogMessage),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(),
            child: Text(l10n.cancelButton),
          ),
          M3EButton.text(
            onPressed: () async {
              navigator.pop();
              try {
                var success = false;
                if (syncProvider != null) {
                  final text = await pickJsonBackupText();
                  if (text == null) return; // 用户取消
                  await syncProvider.commands.backup.importJson(text);
                  success = true;
                }
                if (!currentContext.mounted) return;
                if (success) {
                  notificationService.showSuccessSnackBar(l10n.importSuccess);
                } else {
                  notificationService.showErrorSnackBar(l10n.importFailed);
                }
              } catch (e) {
                if (currentContext.mounted) {
                  notificationService.showErrorSnackBar(l10n.importFailed);
                }
              }
            },
            child: Text(l10n.importButton),
          ),
        ],
      ),
    );
  }
}

/// 导出文件名里的时间戳（冒号在 Windows 文件名里非法）。
String _fileTimestamp() =>
    DateTime.now().toIso8601String().replaceAll(':', '-');

/// 另存结果统一提示：保存成功给出位置，取消静默，失败提示重试。
void _showSaveResult(
  AppLocalizations l10n,
  NotificationService notifications,
  SaveAsResult result,
) {
  switch (result) {
    case SaveAsSaved(:final displayPath, :final kind):
      notifications.showSuccessSnackBar(
        savedLocationMessage(l10n, kind, displayPath),
      );
    case SaveAsCancelled():
      return;
    case SaveAsFailed():
      notifications.showErrorSnackBar(l10n.saveFailed);
  }
}
