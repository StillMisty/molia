import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../services/json_backup_picker.dart';
import '../services/notification_service.dart';
import '../services/save_as.dart';
import '../utils/save_as_label.dart';
import '../widgets/lxmc_import.dart' show importLxmcFavoritesFlow;
import '../widgets/settings/settings_subpage.dart';
import '../widgets/settings/settings_tiles.dart';

/// 设置 › 数据与备份 › 备份与恢复：完整备份导出 / 导入 / 收藏迁移。
///
/// 低频且带破坏性（导入会合并并以备份为准），从设置首屏下沉一页，避免与
/// 日常统计 / 同步入口混排。完整备份只经同步引擎的适配器收集 / 合并；引擎
/// 未挂载（测试）时导出 / 导入都按失败处理（没有可回退的旧数据源）。
class BackupRestorePage extends StatelessWidget {
  const BackupRestorePage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final syncProvider = context.watch<SyncProvider?>();
    return SettingsSubPage(
      title: l10n.settingsBackupRestoreTitle,
      children: [
        SettingsSectionCard(
          children: [
            SettingsNavTile(
              key: const Key('settingsExportItem'),
              icon: Icons.upload_file_rounded,
              title: l10n.exportDataTitle,
              subtitle: l10n.exportDataSubtitle,
              onTap: () => _exportData(context, l10n, syncProvider),
            ),
            SettingsNavTile(
              key: const Key('settingsImportItem'),
              icon: Icons.download_rounded,
              title: l10n.importDataTitle,
              subtitle: l10n.importDataSubtitle,
              onTap: () => _showImportDialog(context, l10n, syncProvider),
            ),
            SettingsNavTile(
              key: const Key('settingsImportFavoritesItem'),
              icon: Icons.favorite_border_rounded,
              title: l10n.libraryImportFavorites,
              subtitle: l10n.libraryImportFavoritesSubtitle,
              onTap: () => importLxmcFavoritesFlow(context),
            ),
          ],
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
