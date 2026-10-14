import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../widgets/settings/settings_tiles.dart';
import 'lyrics_shared_display_section.dart';

/// 歌词与输出页：应用内歌词页（翻译 / 罗马音）+ 全部输出的共享展示策略。
///
/// 两组开关相互独立——`page.*` 只影响播放页歌词，共享项影响桌面歌词 /
/// 通知 / 蓝牙；两侧行副标题都写明了生效范围，避免两个「翻译」互相混淆。
class LyricsContentSettingsPage extends StatelessWidget {
  const LyricsContentSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<LyricsDisplaySettings>();
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.lyricsContentTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
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
        ],
      ),
    );
  }
}
