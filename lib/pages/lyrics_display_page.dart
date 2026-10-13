import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/lyrics_display_provider.dart';
import '../services/lyrics_display/lyrics_output.dart';
import '../widgets/settings/settings_tiles.dart';
import 'lyrics_display/bluetooth_lyrics_settings_page.dart';
import 'lyrics_display/desktop_lyrics_settings_page.dart';
import 'lyrics_display/lyrics_output_settings_page.dart';
import 'lyrics_display/lyrics_page_settings_page.dart';
import 'lyrics_display/notification_lyrics_settings_page.dart';

/// 歌词显示设置 hub：歌词页 / 歌词输出 / 桌面歌词 / 通知·锁屏 / 蓝牙。
///
/// - 输出分组入口按平台能力显隐（不支持的平台直接隐藏，避免开关撒谎）；
/// - 「歌词页」与「歌词输出」与输出能力无关，始终可见；
/// - 具体配置在二级子页（经 [openSettingsSubPage] 推入），本页只做导航与
///   能力复查。
class LyricsDisplayPage extends StatefulWidget {
  const LyricsDisplayPage({super.key});

  @override
  State<LyricsDisplayPage> createState() => _LyricsDisplayPageState();
}

class _LyricsDisplayPageState extends State<LyricsDisplayPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<LyricsDisplayProvider>().refreshCapabilities();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      // 从系统「显示在其他应用上层」授权页返回：复查能力。
      context.read<LyricsDisplayProvider>().refreshCapabilities();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final display = context.watch<LyricsDisplayProvider>();
    final desktopCapability = display.capabilityOf(LyricsOutputIds.desktop);
    final mediaCapability = display.capabilityOf(LyricsOutputIds.media);
    final hasAnySupported =
        desktopCapability != LyricsOutputCapability.unsupported ||
            mediaCapability != LyricsOutputCapability.unsupported;

    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.settingsLyricsDisplayTitle),
        automaticallyImplyLeading: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(kSettingsPadding),
          children: [
            SettingsSectionCard(
              children: [
                SettingsNavTile(
                  key: const Key('lyricsPageEntry'),
                  icon: Icons.article_rounded,
                  title: l10n.lyricsPageTitle,
                  subtitle: l10n.lyricsDisplayPageEntrySubtitle,
                  onTap: () => openSettingsSubPage(
                    context,
                    const LyricsPageSettingsPage(),
                  ),
                ),
                SettingsNavTile(
                  key: const Key('lyricsOutputsEntry'),
                  icon: Icons.tune_rounded,
                  title: l10n.lyricsDisplaySharedTitle,
                  subtitle: l10n.lyricsDisplayOutputsEntrySubtitle,
                  onTap: () => openSettingsSubPage(
                    context,
                    const LyricsOutputSettingsPage(),
                  ),
                ),
                if (desktopCapability != LyricsOutputCapability.unsupported)
                  SettingsNavTile(
                    key: const Key('lyricsDesktopEntry'),
                    icon: Icons.picture_in_picture_alt_rounded,
                    title: l10n.lyricsDesktopTitle,
                    subtitle: l10n.lyricsDesktopEntrySubtitle,
                    onTap: () => openSettingsSubPage(
                      context,
                      const DesktopLyricsSettingsPage(),
                    ),
                  ),
                if (mediaCapability != LyricsOutputCapability.unsupported) ...[
                  SettingsNavTile(
                    key: const Key('lyricsNotificationEntry'),
                    icon: Icons.notifications_active_rounded,
                    title: l10n.lyricsNotificationTitle,
                    subtitle: l10n.lyricsNotificationEntrySubtitle,
                    onTap: () => openSettingsSubPage(
                      context,
                      const NotificationLyricsSettingsPage(),
                    ),
                  ),
                  SettingsNavTile(
                    key: const Key('lyricsBluetoothEntry'),
                    icon: Icons.bluetooth_rounded,
                    title: l10n.lyricsBluetoothTitle,
                    subtitle: l10n.lyricsBluetoothEntrySubtitle,
                    onTap: () => openSettingsSubPage(
                      context,
                      const BluetoothLyricsSettingsPage(),
                    ),
                  ),
                ],
              ],
            ),
            if (!hasAnySupported)
              Padding(
                padding: const EdgeInsets.only(top: kSettingsSectionSpacing),
                child: Text(
                  l10n.lyricsDisplayUnsupported,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            // 平台支持但媒体会话初始化失败（音频服务 init 返回 null）：
            // 给出可见提示——否则输出分组消失、只剩日志，用户无法自查。
            if (display.mediaSessionInitFailed)
              Padding(
                padding: const EdgeInsets.only(top: kSettingsSectionSpacing),
                child: Text(
                  l10n.lyricsMediaSessionUnavailable,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
