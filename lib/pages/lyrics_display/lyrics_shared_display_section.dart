import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../widgets/settings/settings_tiles.dart';

/// 歌词输出共享展示项：翻译 / 罗马音 / 偏移 / 未同步回退。
///
/// 这些策略由 `LyricsDisplayProvider` 在 Dart 侧统一应用，改一次对桌面
/// 悬浮窗、通知栏·锁屏与蓝牙全部生效。「歌词输出」页与桌面歌词页内联的
/// 是同一组行（同一 provider 源），不存在两份状态。
class LyricsSharedDisplaySection extends StatelessWidget {
  const LyricsSharedDisplaySection({super.key, this.title});

  /// 分组标题；缺省不显示（由页面标题承担语义时）。
  final String? title;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<LyricsDisplaySettings>();
    return SettingsSectionCard(
      title: title,
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
          onChanged: (value) => settings.setOffsetMs((value / 50).round() * 50),
        ),
        SettingsChoiceRow<UnsyncedBehavior>(
          icon: Icons.help_outline_rounded,
          title: l10n.lyricsDisplayUnsynced,
          value: settings.unsyncedBehavior,
          options: [
            (UnsyncedBehavior.title, l10n.lyricsDisplayUnsyncedTitle),
            (UnsyncedBehavior.hide, l10n.lyricsDisplayUnsyncedHide),
            (UnsyncedBehavior.firstLine, l10n.lyricsDisplayUnsyncedFirstLine),
          ],
          icons: const {
            UnsyncedBehavior.title: Icons.title_rounded,
            UnsyncedBehavior.hide: Icons.visibility_off_rounded,
            UnsyncedBehavior.firstLine: Icons.short_text_rounded,
          },
          onChanged: settings.setUnsyncedBehavior,
        ),
      ],
    );
  }
}
