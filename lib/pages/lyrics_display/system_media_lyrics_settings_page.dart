import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/lyrics_display_provider.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../services/notification_permission.dart';
import '../../theme/m3e_context.dart';
import '../../widgets/settings/settings_tiles.dart';
import 'lyrics_settings_common.dart';

/// 系统媒体歌词页：通知栏·锁屏 + 蓝牙 两个分组。
///
/// 两组共用同一媒体元数据输出（通知与蓝牙 profile 合成后写入 MediaItem），
/// 选项构造集中在 [lyricsMetadataTargetOptions] 等处，避免两页口径漂移。
/// 通知组开关在权限被拒时给系统设置深链；蓝牙组顶部有一行 A2DP 连接事实。
class SystemMediaLyricsSettingsPage extends StatefulWidget {
  const SystemMediaLyricsSettingsPage({super.key});

  @override
  State<SystemMediaLyricsSettingsPage> createState() =>
      _SystemMediaLyricsSettingsPageState();
}

class _SystemMediaLyricsSettingsPageState
    extends State<SystemMediaLyricsSettingsPage> with WidgetsBindingObserver {
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
    final display = context.watch<LyricsDisplayProvider>();
    final scheme = Theme.of(context).colorScheme;
    final showPermissionHint = settings.notificationEnabled &&
        _permission != NotificationPermissionStatus.granted &&
        _permission != NotificationPermissionStatus.unsupported;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.lyricsSystemMediaTitle),
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
            title: l10n.lyricsNotificationTitle,
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
          const SizedBox(height: kSettingsSectionSpacing),
          SettingsSectionCard(
            title: l10n.lyricsBluetoothTitle,
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
                      style: context.typeScale.bodySmall.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
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
