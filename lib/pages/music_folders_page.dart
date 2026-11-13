import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:file_picker/file_picker.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/local/local_library_service.dart';
import '../services/local/music_folders.dart';
import '../services/notification_service.dart';
import '../widgets/empty_state.dart';
import '../widgets/settings/settings_subpage.dart';
import '../widgets/settings/settings_tiles.dart';

/// 音乐文件夹：添加 / 移除 / 手动扫描 / 进度与摘要（设备本地配置）。
///
/// 入口在「数据与存储 › 下载设置」；iOS 不展示（没有目录访问）。
class MusicFoldersPage extends StatelessWidget {
  const MusicFoldersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final service = context.watch<LocalLibraryService?>();
    return SettingsSubPage(
      title: l10n.musicFoldersTitle,
      children: [
        SettingsSectionCard(
          title: l10n.musicFoldersTitle,
          children: [
            SettingsNavTile(
              key: const Key('musicFoldersAdd'),
              icon: Icons.create_new_folder_rounded,
              title: l10n.musicFoldersAdd,
              subtitle: l10n.musicFoldersSubtitle,
              onTap: service == null
                  ? null
                  : () => _addFolder(context, l10n, service),
            ),
            for (final folder
                in service?.folders.folders ?? const <MusicFolder>[])
              _FolderRow(folder: folder, service: service!),
            if (service != null && service.scanning)
              SettingsInfoTile(
                icon: Icons.hourglass_top_rounded,
                title: l10n.musicFoldersScanning(
                  service.progress == null ? 0 : service.progress!.processed,
                ),
                subtitle: '',
                trailing: M3EButton.text(
                  onPressed: service.cancelScan,
                  child: Text(l10n.musicFoldersCancelScan),
                ),
              ),
            if (defaultTargetPlatform == TargetPlatform.android)
              SettingsSectionHint(text: l10n.musicFoldersAndroidNote),
          ],
        ),
        if (service != null && service.folders.folders.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: kSettingsSectionSpacing),
            child: EmptyState(
              icon: Icons.folder_off_rounded,
              message: l10n.musicFoldersEmptyTitle,
              hint: l10n.musicFoldersEmptyBody,
            ),
          ),
      ],
    );
  }

  Future<void> _addFolder(
    BuildContext context,
    AppLocalizations l10n,
    LocalLibraryService service,
  ) async {
    final notifications = context.read<NotificationService?>();
    String? picked;
    try {
      picked = await FilePicker.getDirectoryPath(
        dialogTitle: l10n.musicFoldersAdd,
      );
    } catch (_) {
      picked = null;
    }
    if (picked == null || picked.isEmpty) return;
    final result = await service.addFolder(picked);
    switch (result) {
      case MusicFolderAddResult.added:
        notifications?.showSnackBar(l10n.musicFoldersAdded);
      case MusicFolderAddResult.duplicate:
        notifications?.showSnackBar(l10n.musicFoldersDuplicate);
      case MusicFolderAddResult.nested:
        notifications?.showSnackBar(l10n.musicFoldersNested);
      case MusicFolderAddResult.invalid:
        notifications?.showSnackBar(l10n.musicFoldersInvalid);
    }
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({required this.folder, required this.service});

  final MusicFolder folder;
  final LocalLibraryService service;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scanning = service.scanning && service.scanningFolderId == folder.id;
    return SettingsInfoTile(
      icon: Icons.folder_rounded,
      title: folder.root,
      subtitle: scanning
          ? l10n.musicFoldersScanning(service.progress?.processed ?? 0)
          : _summaryText(l10n, folder.lastScan),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          M3EIconButton(
            variant: M3EIconButtonVariant.standard,
            icon: Icon(scanning ? Icons.stop_rounded : Icons.refresh_rounded),
            semanticLabel: scanning
                ? l10n.musicFoldersCancelScan
                : l10n.musicFoldersRescan,
            onPressed: scanning
                ? service.cancelScan
                : () => unawaited(service.scanFolder(folder.id)),
          ),
          M3EMenu.entries(
            position: M3EMenuAnchorPosition.bottomEnd,
            anchorBuilder: (context, open) => M3EIconButton(
              variant: M3EIconButtonVariant.standard,
              icon: const Icon(Icons.more_vert_rounded),
              semanticLabel: l10n.musicFoldersRemove,
              onPressed: open,
            ),
            onSelected: (value) {
              if (value == 'remove') unawaited(service.removeFolder(folder.id));
            },
            entries: [
              M3EMenuEntry(
                label: l10n.musicFoldersRemove,
                value: 'remove',
                isDestructive: true,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _summaryText(AppLocalizations l10n, MusicFolderScanSummary? summary) {
    if (summary == null) return l10n.musicFoldersSubtitle;
    if (summary.unavailable) return l10n.musicFoldersUnavailable;
    if (summary.cancelled) return l10n.musicFoldersCancelled;
    return l10n.musicFoldersSummary(
      summary.added,
      summary.updated,
      summary.skipped,
    );
  }
}
