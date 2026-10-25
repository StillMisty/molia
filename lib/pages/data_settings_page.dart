import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../services/json_backup_picker.dart';
import '../services/notification_service.dart';
import '../services/play_statistics_service.dart';
import '../services/save_as.dart';
import '../utils/save_as_label.dart';
import '../widgets/lxmc_import.dart' show importLxmcFavoritesFlow;
import '../widgets/settings/settings_tiles.dart';
import 'cache_management_page.dart';
import 'download_settings_page.dart';
import 'downloads_manage_page.dart';

/// 数据与存储子页：缓存、听歌统计与数据导入导出。
///
/// 从设置首屏「通用与数据」进入，在设置弹层内部导航（见 `settings_page.dart`）。
class DataSettingsPage extends StatelessWidget {
  const DataSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 完整备份只经同步引擎的适配器收集/合并；引擎未挂载（测试）时导出 /
    // 导入都按失败处理（没有可回退的旧数据源）。
    final syncProvider = context.watch<SyncProvider?>();
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.dataManagementTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          SettingsSectionCard(
            title: l10n.settingsDataStorageSection,
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
              // 统计采集开关（关闭 = 停止记录新事件，已有数据保留）；
              // 统计明细入口在设置首屏「数据」卡（与听歌统计同一处）。
              ValueListenableBuilder<bool>(
                valueListenable:
                    context.read<PlayStatisticsService>().enabledNotifier,
                builder: (context, enabled, _) => SettingsSwitchTile(
                  switchKey: const Key('settingsPlayStatisticsSwitch'),
                  icon: Icons.query_stats_rounded,
                  title: l10n.statsRecordSwitch,
                  subtitle: l10n.statsRecordSwitchSubtitle,
                  value: enabled,
                  onChanged: (value) => unawaited(
                    context.read<PlayStatisticsService>().setEnabled(value),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: kSettingsSectionSpacing),
          SettingsSectionCard(
            title: l10n.settingsDataPortabilitySection,
            children: [
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
            ],
          ),
        ],
      ),
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
      // 完整备份：同步备份模块收集全部类别（凭证类默认不含）。
      final json = await syncProvider.exportBackupJson();
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
                  await syncProvider.importBackupJson(text);
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
