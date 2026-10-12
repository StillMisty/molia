import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../widgets/settings/settings_tiles.dart';

/// 歌词页（应用内）子页：只控制播放页歌词渲染的翻译 / 罗马音。
///
/// 与输出侧开关相互独立（[LyricsOutputSettingsPage] 管悬浮窗 / 通知 /
/// 蓝牙共用项），所以两组开关不共用同一配置字段。
class LyricsPageSettingsPage extends StatelessWidget {
  const LyricsPageSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<LyricsDisplaySettings>();
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.lyricsPageTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          SettingsSectionCard(
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
        ],
      ),
    );
  }
}
