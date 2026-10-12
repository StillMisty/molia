import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../widgets/settings/settings_tiles.dart';

/// 歌词输出子页：所有输出（悬浮窗 / 通知 / 蓝牙）共用的展示策略。
///
/// 翻译、罗马音、偏移与无时间轴处理都在 Dart 侧统一应用（见
/// `LyricsDisplayProvider`），所以这里改一次全输出生效。
class LyricsOutputSettingsPage extends StatelessWidget {
  const LyricsOutputSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<LyricsDisplaySettings>();
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.lyricsDisplaySharedTitle),
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
                subtitle: l10n.lyricsDisplayTranslationSubtitle,
                value: settings.translationEnabled,
                onChanged: settings.setTranslationEnabled,
              ),
              SettingsSwitchTile(
                icon: Icons.record_voice_over_rounded,
                title: l10n.lyricsDisplayRoma,
                subtitle: l10n.lyricsDisplayRomaSubtitle,
                value: settings.romaEnabled,
                onChanged: settings.setRomaEnabled,
              ),
              SettingsSliderRow(
                icon: Icons.sync_alt_rounded,
                title: l10n.lyricsDisplayOffset,
                valueLabel: l10n.lyricsDisplayOffsetValue(settings.offsetMs),
                value: settings.offsetMs.toDouble(),
                min: -500,
                max: 500,
                divisions: 20,
                // 滑杆步进 50ms：够用且不与歌词时间戳的精度纠缠。
                onChanged: (value) =>
                    settings.setOffsetMs((value / 50).round() * 50),
              ),
              SettingsChoiceRow<UnsyncedBehavior>(
                icon: Icons.help_outline_rounded,
                title: l10n.lyricsDisplayUnsynced,
                value: settings.unsyncedBehavior,
                options: [
                  (UnsyncedBehavior.title, l10n.lyricsDisplayUnsyncedTitle),
                  (UnsyncedBehavior.hide, l10n.lyricsDisplayUnsyncedHide),
                  (
                    UnsyncedBehavior.firstLine,
                    l10n.lyricsDisplayUnsyncedFirstLine,
                  ),
                ],
                onChanged: settings.setUnsyncedBehavior,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
