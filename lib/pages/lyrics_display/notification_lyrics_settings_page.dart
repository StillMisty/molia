import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../widgets/settings/settings_tiles.dart';
import 'lyrics_settings_common.dart';

/// 通知栏 · 锁屏歌词子页：当前行写入媒体元数据的目标 / 格式 / 回退。
///
/// 「目标」保持下拉（4 项且文案较长），「格式」用分段按钮（3 项短文案）。
class NotificationLyricsSettingsPage extends StatelessWidget {
  const NotificationLyricsSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<LyricsDisplaySettings>();
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.lyricsNotificationTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
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
