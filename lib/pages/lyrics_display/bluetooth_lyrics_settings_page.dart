import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/lyrics_display_provider.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../widgets/settings/settings_tiles.dart';
import 'lyrics_settings_common.dart';

/// 蓝牙歌词子页：面向 A2DP 车机 / 耳机的媒体元数据写入。
///
/// 顶部状态行说明当前蓝牙音频连接事实（[LyricsDisplayProvider.a2dpConnected]），
/// 「仅 A2DP」开关决定未连接时是否停写。
class BluetoothLyricsSettingsPage extends StatelessWidget {
  const BluetoothLyricsSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<LyricsDisplaySettings>();
    final display = context.watch<LyricsDisplayProvider>();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.lyricsBluetoothTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          SettingsSectionCard(
            children: [
              // 连接状态行：只读事实，不参与配置。
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(
                      display.a2dpConnected
                          ? Icons.bluetooth_connected_rounded
                          : Icons.bluetooth_disabled_rounded,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      display.a2dpConnected
                          ? l10n.lyricsBluetoothStatusConnected
                          : l10n.lyricsBluetoothStatusDisconnected,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              SettingsSwitchTile(
                icon: Icons.bluetooth_rounded,
                title: l10n.lyricsBluetoothEnable,
                subtitle: l10n.lyricsBluetoothEnableSubtitle,
                value: settings.bluetoothEnabled,
                onChanged: settings.setBluetoothEnabled,
              ),
              SettingsSwitchTile(
                icon: Icons.headset_rounded,
                title: l10n.lyricsBluetoothOnlyA2dp,
                subtitle: '',
                value: settings.bluetoothOnlyWhenA2dp,
                onChanged: settings.setBluetoothOnlyWhenA2dp,
              ),
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
      ),
    );
  }
}
