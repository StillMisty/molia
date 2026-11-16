import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../widgets/settings/settings_subpage.dart';
import '../../widgets/settings/settings_tiles.dart';
import 'lyrics_settings_common.dart';

/// 系统媒体歌词高级页：通知栏·锁屏与车机/蓝牙的细节策略。
///
/// 首屏只留两个总开关（在「歌词与输出」页），这里才出现目标 / 格式 /
/// 翻译 / 暂停行为 / 更新间隔。两组共用同一媒体元数据输出，选项构造集中在
/// [lyricsMetadataTargetOptions] 等处，避免两页口径漂移。
class SystemMediaLyricsAdvancedPage extends StatelessWidget {
  const SystemMediaLyricsAdvancedPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<LyricsDisplaySettings>();
    return SettingsSubPage(
      title: l10n.lyricsSystemMediaAdvancedTitle,
      children: [
        SettingsSectionCard(
          title: l10n.lyricsNotificationTitle,
          children: [
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
        const SizedBox(height: kSettingsSectionSpacing),
        SettingsSectionCard(
          title: l10n.lyricsBluetoothTitle,
          children: [
            SettingsDropdownRow<LyricsMetadataTarget>(
              icon: Icons.place_rounded,
              title: l10n.lyricsMetadataTarget,
              value: settings.bluetoothTarget,
              options: lyricsMetadataTargetOptions(l10n),
              onChanged: settings.setBluetoothTarget,
            ),
            SettingsChoiceRow<LyricsMetadataFormat>(
              icon: Icons.format_quote_rounded,
              title: l10n.lyricsMetadataFormat,
              value: settings.bluetoothFormat,
              options: lyricsMetadataFormatOptions(l10n),
              onChanged: settings.setBluetoothFormat,
            ),
            SettingsSwitchTile(
              icon: Icons.translate_rounded,
              title: l10n.lyricsMetadataIncludeTranslation,
              subtitle: '',
              value: settings.bluetoothIncludeTranslation,
              onChanged: settings.setBluetoothIncludeTranslation,
            ),
            SettingsChoiceRow<int>(
              icon: Icons.timer_rounded,
              title: l10n.lyricsBluetoothUpdateInterval,
              value: settings.bluetoothUpdateIntervalMs,
              options: [
                (0, l10n.lyricsBluetoothIntervalLine),
                (1000, l10n.lyricsBluetoothInterval1s),
                (2000, l10n.lyricsBluetoothInterval2s),
              ],
              onChanged: settings.setBluetoothUpdateIntervalMs,
            ),
            SettingsChoiceRow<LyricsPauseBehavior>(
              icon: Icons.pause_rounded,
              title: l10n.lyricsMetadataPauseBehavior,
              value: settings.bluetoothPauseBehavior,
              options: lyricsPauseBehaviorOptions(l10n),
              onChanged: settings.setBluetoothPauseBehavior,
            ),
          ],
        ),
      ],
    );
  }
}
