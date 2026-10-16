/// 下载设置子页：保存位置 / 文件名格式 / 标签嵌入 / 下载通知。
///
/// 从设置 › 数据与存储进入（与缓存管理同组）。保存位置在桌面可自选目录
/// （移动端固定在应用目录：Android 公共目录走 MediaStore，见 #17）。
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/download/download_service.dart';
import '../services/download/download_settings.dart';
import '../services/notification_permission.dart';
import '../services/notification_service.dart';
import '../widgets/settings/settings_tiles.dart';

/// 桌面平台支持自选保存目录（dart:io 路径语义；移动端 SAF/沙箱另论）。
bool get _supportsCustomSaveDir {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS;
}

class DownloadSettingsPage extends StatelessWidget {
  const DownloadSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<DownloadSettings>();
    final downloads = context.watch<DownloadService?>();
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.downloadSettingsTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          SettingsSectionCard(
            children: [
              SettingsValueTile(
                key: const Key('downloadSaveLocationItem'),
                icon: Icons.folder_rounded,
                title: l10n.downloadSaveLocation,
                subtitle: _supportsCustomSaveDir
                    ? null
                    : l10n.downloadSaveLocationFixedHint,
                value: settings.saveDir.isEmpty
                    ? l10n.downloadSaveLocationDefault
                    : settings.saveDir,
                onTap: _supportsCustomSaveDir
                    ? () => unawaited(_pickDirectory(context, settings))
                    : () => M3ESnackbar.show(
                          context,
                          message: l10n.downloadSaveLocationFixedHint,
                        ),
              ),
              SettingsValueTile(
                key: const Key('downloadFilenameTemplateItem'),
                icon: Icons.edit_note_rounded,
                title: l10n.downloadFilenameTemplate,
                subtitle: l10n.downloadFilenameTemplateHint,
                value: settings.filenameTemplate,
                onTap: () => unawaited(_editTemplate(context, settings)),
              ),
              SettingsSwitchTile(
                switchKey: const Key('downloadEmbedTagsSwitch'),
                icon: Icons.music_note_rounded,
                title: l10n.downloadEmbedTags,
                subtitle: l10n.downloadEmbedTagsSubtitle,
                value: settings.embedTags,
                onChanged: (value) => unawaited(settings.setEmbedTags(value)),
              ),
              // 公共目录发布只在 Android 有语义（其余平台的下载根目录本身
              // 就是公共目录）；发布器不支持时整行不显示。
              if (downloads?.publisherSupported ?? false)
                SettingsSwitchTile(
                  switchKey: const Key('downloadPublishPublicSwitch'),
                  icon: Icons.public_rounded,
                  title: l10n.downloadPublishToPublicDir,
                  subtitle: l10n.downloadPublishToPublicDirSubtitle,
                  value: settings.publishToPublicDir,
                  onChanged: (value) =>
                      unawaited(settings.setPublishToPublicDir(value)),
                ),
              // 下载通知只在 Android 有语义（前台服务 + 通知栏进度）；
              // 打开时顺手补一次通知权限请求（用户主动动作，不打扰）。
              if (downloads?.notificationsSupported ?? false)
                SettingsSwitchTile(
                  switchKey: const Key('downloadNotificationsSwitch'),
                  icon: Icons.notifications_active_rounded,
                  title: l10n.downloadNotifications,
                  subtitle: l10n.downloadNotificationsSubtitle,
                  value: settings.notifications,
                  onChanged: (value) {
                    unawaited(settings.setNotifications(value));
                    if (value) {
                      unawaited(NotificationPermission.ensureRequested());
                    }
                  },
                ),
            ],
          ),
          const SizedBox(height: kSettingsSectionSpacing),
          // 实际下载目录（按平台 / 自定义解析；存储不可用时说明不支持）。
          SettingsSectionCard(
            children: [
              if (downloads == null || !downloads.supported)
                SettingsInfoTile(
                  key: const Key('downloadLocationInfoItem'),
                  icon: Icons.download_rounded,
                  title: l10n.downloadLocationInfo,
                  subtitle: l10n.downloadLocationUnsupported,
                )
              else
                FutureBuilder<String?>(
                  future: downloads.rootPath(),
                  builder: (context, snapshot) => SettingsInfoTile(
                    key: const Key('downloadLocationInfoItem'),
                    icon: Icons.download_rounded,
                    title: l10n.downloadLocationInfo,
                    subtitle: snapshot.data ?? l10n.cacheUsageComputing,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 选择保存目录（桌面）。
  Future<void> _pickDirectory(
    BuildContext context,
    DownloadSettings settings,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final notifications = context.read<NotificationService?>();
    String? picked;
    try {
      picked = await FilePicker.getDirectoryPath(
        dialogTitle: l10n.downloadPickDirectory,
      );
    } catch (_) {
      picked = null;
    }
    if (picked == null || picked.isEmpty) return;
    await settings.setSaveDir(picked);
    notifications?.showSnackBar(l10n.save);
  }

  /// 编辑文件名模板：实时预览 + 恢复默认。
  Future<void> _editTemplate(
    BuildContext context,
    DownloadSettings settings,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: settings.filenameTemplate);
    final navigator = Navigator.of(context, rootNavigator: true);
    final result = await M3EDialog.show<String>(
      context,
      dialog: StatefulBuilder(
        builder: (context, setDialogState) {
          final preview = DownloadSettings.applyTemplate(
            controller.text,
            const {
              'artist': '歌手',
              'title': '歌名',
              'album': '专辑',
            },
          );
          return M3EDialog(
            title: l10n.downloadFilenameTemplate,
            content: SizedBox(
              width: settingsDialogWidth(context),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  M3ETextField(
                    controller: controller,
                    autofocus: true,
                    placeholder: l10n.downloadFilenameTemplate,
                    onChanged: (_) => setDialogState(() {}),
                    onSubmitted: (_) => navigator.pop(controller.text),
                  ),
                  const SizedBox(height: kSettingsSmallSpacing),
                  Text(
                    l10n.downloadFilenameTemplateHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${l10n.downloadFilenamePreview}: $preview',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            actions: [
              M3EButton.text(
                onPressed: () {
                  controller.text = kDefaultFilenameTemplate;
                  setDialogState(() {});
                },
                child: Text(l10n.downloadReset),
              ),
              M3EButton.text(
                onPressed: () => navigator.pop(),
                child: Text(l10n.cancel),
              ),
              M3EButton.filled(
                onPressed: () => navigator.pop(controller.text),
                child: Text(l10n.save),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (result == null) return;
    await settings.setFilenameTemplate(result);
  }
}
