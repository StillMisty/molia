import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../services/notification_permission.dart';
import '../../widgets/settings/settings_tiles.dart';
import 'lyrics_settings_common.dart';

/// 通知栏 · 锁屏歌词子页：当前行写入媒体元数据的目标 / 格式 / 回退。
///
/// 「目标」保持下拉（4 项且文案较长），「格式」用分段按钮（3 项短文案）。
/// 通知权限被拒时给系统设置深链（媒体通知豁免权限，但部分 ROM 缺权限时
/// 通知仍不展示，这里是唯一的排查入口）。
class NotificationLyricsSettingsPage extends StatefulWidget {
  const NotificationLyricsSettingsPage({super.key});

  @override
  State<NotificationLyricsSettingsPage> createState() =>
      _NotificationLyricsSettingsPageState();
}

class _NotificationLyricsSettingsPageState
    extends State<NotificationLyricsSettingsPage> with WidgetsBindingObserver {
  NotificationPermissionStatus _permission =
      NotificationPermissionStatus.unsupported;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统通知设置页返回：复查权限，提示行随之消失。
    if (state == AppLifecycleState.resumed) _refreshPermission();
  }

  Future<void> _refreshPermission() async {
    final status = await NotificationPermission.status();
    if (!mounted || status == _permission) return;
    setState(() => _permission = status);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<LyricsDisplaySettings>();
    final showPermissionHint = settings.notificationEnabled &&
        _permission != NotificationPermissionStatus.granted &&
        _permission != NotificationPermissionStatus.unsupported;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.lyricsNotificationTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          // 权限被拒：设置深链（允许通知后媒体通知/锁屏卡才能稳定展示）。
          if (showPermissionHint) ...[
            SettingsSectionCard(
              children: [
                SettingsNavTile(
                  key: const Key('lyricsNotificationPermissionItem'),
                  icon: Icons.notifications_off_rounded,
                  title: l10n.lyricsNotificationPermissionTitle,
                  subtitle: l10n.lyricsNotificationPermissionSubtitle,
                  onTap: NotificationPermission.openSettings,
                ),
              ],
            ),
            const SizedBox(height: kSettingsSectionSpacing),
          ],
          SettingsSectionCard(
            children: [
              SettingsSwitchTile(
                icon: Icons.notifications_active_rounded,
                title: l10n.lyricsNotificationEnable,
                subtitle: l10n.lyricsNotificationEnableSubtitle,
                value: settings.notificationEnabled,
                onChanged: settings.setNotificationEnabled,
              ),
              SettingsDropdownRow<LyricsMetadataTarget>(
                icon: Icons.place_rounded,
                title: l10n.lyricsMetadataTarget,
                value: settings.notificationTarget,
                options: lyricsMetadataTargetOptions(l10n),
                onChanged: settings.setNotificationTarget,
              ),
              SettingsChoiceRow<LyricsMetadataFormat>(
                icon: Icons.format_quote_rounded,
                title: l10n.lyricsMetadataFormat,
                value: settings.notificationFormat,
                options: lyricsMetadataFormatOptions(l10n),
                onChanged: settings.setNotificationFormat,
              ),
              SettingsSwitchTile(
                icon: Icons.translate_rounded,
                title: l10n.lyricsMetadataIncludeTranslation,
                subtitle: '',
                value: settings.notificationIncludeTranslation,
                onChanged: settings.setNotificationIncludeTranslation,
              ),
              SettingsChoiceRow<LyricsPauseBehavior>(
                icon: Icons.pause_rounded,
                title: l10n.lyricsMetadataPauseBehavior,
                value: settings.notificationPauseBehavior,
                options: lyricsPauseBehaviorOptions(l10n),
                onChanged: settings.setNotificationPauseBehavior,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
