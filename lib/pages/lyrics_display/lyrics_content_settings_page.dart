import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/lyrics_display_provider.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../services/lyrics_display/lyrics_output.dart';
import '../../services/notification_permission.dart';
import '../../widgets/settings/settings_subpage.dart';
import '../../widgets/settings/settings_tiles.dart';
import 'lyrics_shared_display_section.dart';
import 'system_media_lyrics_settings_page.dart';

/// 歌词与输出页：应用内歌词、共享展示、通知栏·锁屏与车机/蓝牙。
///
/// 首屏只给两个总开关；输出目标 / 格式 / 翻译 / 暂停行为 / 更新间隔等
/// 细节收进「高级」。这样首屏的「系统媒体歌词」入口可以并回本页，歌词
/// 只剩桌面歌词与「歌词与输出」两条路径。
class LyricsContentSettingsPage extends StatefulWidget {
  const LyricsContentSettingsPage({super.key, this.embedded = false});

  /// 作为二级页正文挂进外层 chrome（侧边弹层 / 全屏路由的 AppBar）时为
  /// true：不自带 Scaffold + AppBar，避免双层标题栏。
  final bool embedded;

  @override
  State<LyricsContentSettingsPage> createState() =>
      _LyricsContentSettingsPageState();
}

class _LyricsContentSettingsPageState extends State<LyricsContentSettingsPage>
    with WidgetsBindingObserver {
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
    final display = context.watch<LyricsDisplayProvider?>();
    final mediaSupported =
        display != null &&
        display.capabilityOf(LyricsOutputIds.media) !=
            LyricsOutputCapability.unsupported;
    final showPermissionHint =
        settings.notificationEnabled &&
        _permission != NotificationPermissionStatus.granted &&
        _permission != NotificationPermissionStatus.unsupported;
    final children = <Widget>[
      SettingsSectionCard(
        title: l10n.lyricsPageTitle,
        children: [
          SettingsSwitchTile(
            icon: Icons.translate_rounded,
            title: l10n.lyricsDisplayTranslation,
            subtitle: l10n.lyricsPageTranslationSubtitle,
            value: settings.pageTranslationEnabled,
            onChanged: settings.setPageTranslationEnabled,
          ),
          SettingsSwitchTile(
            icon: Icons.record_voice_over_rounded,
            title: l10n.lyricsDisplayRoma,
            subtitle: l10n.lyricsPageRomaSubtitle,
            value: settings.pageRomaEnabled,
            onChanged: settings.setPageRomaEnabled,
          ),
        ],
      ),
      const SizedBox(height: kSettingsSectionSpacing),
      LyricsSharedDisplaySection(title: l10n.lyricsDisplaySharedTitle),
      if (mediaSupported) ...[
        const SizedBox(height: kSettingsSectionSpacing),
        SettingsSectionCard(
          title: l10n.lyricsNotificationTitle,
          footer: display.mediaSessionInitFailed
              ? SettingsSectionHint(text: l10n.lyricsMediaSessionUnavailable)
              : null,
          children: [
            SettingsSwitchTile(
              switchKey: const Key('lyricsNotificationSwitch'),
              icon: Icons.notifications_active_rounded,
              title: l10n.lyricsNotificationEnable,
              subtitle: l10n.lyricsNotificationEnableSubtitle,
              value: settings.notificationEnabled,
              onChanged: settings.setNotificationEnabled,
            ),
            // 权限被拒：设置深链（允许通知后媒体通知/锁屏卡才能稳定展示）。
            if (showPermissionHint)
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
        SettingsSectionCard(
          title: l10n.lyricsBluetoothTitle,
          children: [
            SettingsSwitchTile(
              switchKey: const Key('lyricsBluetoothSwitch'),
              icon: Icons.bluetooth_rounded,
              title: l10n.lyricsBluetoothEnable,
              subtitle: l10n.lyricsBluetoothEnableSubtitle,
              value: settings.bluetoothEnabled,
              onChanged: settings.setBluetoothEnabled,
            ),
            SettingsSwitchTile(
              switchKey: const Key('lyricsBluetoothA2dpSwitch'),
              icon: Icons.headset_rounded,
              title: l10n.lyricsBluetoothOnlyA2dp,
              subtitle: '',
              value: settings.bluetoothOnlyWhenA2dp,
              onChanged: settings.setBluetoothOnlyWhenA2dp,
            ),
          ],
        ),
        const SizedBox(height: kSettingsSectionSpacing),
        SettingsSectionCard(
          children: [
            SettingsNavTile(
              key: const Key('lyricsSystemMediaAdvancedItem'),
              icon: Icons.tune_rounded,
              title: l10n.lyricsSystemMediaAdvancedTitle,
              subtitle: l10n.lyricsSystemMediaAdvancedSubtitle,
              onTap: () => openSettingsSubPage(
                context,
                const SystemMediaLyricsAdvancedPage(),
              ),
            ),
          ],
        ),
      ],
    ];
    if (widget.embedded) return SettingsSubPageList(children: children);
    return SettingsSubPage(title: l10n.lyricsContentTitle, children: children);
  }
}
