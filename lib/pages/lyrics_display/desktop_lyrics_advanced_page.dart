import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/theme_provider.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../theme/scheme_builder.dart';
import '../../widgets/settings/settings_subpage.dart';
import '../../widgets/settings/settings_tiles.dart';
import 'lyric_color_row.dart';

/// 桌面歌词高级页：对齐、阴影、冻结、动画、暂停回退与控制条按钮。
///
/// 主页面只留每天会改的开关、字号、透明度、宽度与播放/未播放颜色；
/// 这里放「有就行、很少改」的行为项，避免主页面堆到二十多行。
class DesktopLyricsAdvancedPage extends StatelessWidget {
  const DesktopLyricsAdvancedPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<LyricsDisplaySettings>();
    final themeProvider = context.watch<ThemeProvider>();
    final scheme = resolveSurfaceScheme(
      settings.desktopSchemeSource,
      appScheme: themeProvider.colorScheme,
      artworkScheme: themeProvider.artworkColorScheme,
    );
    return SettingsSubPage(
      title: l10n.lyricsDesktopAdvancedTitle,
      children: [
        SettingsSectionCard(
          title: l10n.lyricsDesktopAdvancedTitle,
          children: [
            SettingsChoiceRow<DesktopTextAlignX>(
              icon: Icons.format_align_center_rounded,
              title: l10n.lyricsDesktopAlign,
              value: settings.desktopTextAlignX,
              options: [
                (DesktopTextAlignX.left, l10n.lyricsDesktopAlignLeft),
                (DesktopTextAlignX.center, l10n.lyricsDesktopAlignCenter),
                (DesktopTextAlignX.right, l10n.lyricsDesktopAlignRight),
              ],
              icons: const {
                DesktopTextAlignX.left: Icons.format_align_left_rounded,
                DesktopTextAlignX.center: Icons.format_align_center_rounded,
                DesktopTextAlignX.right: Icons.format_align_right_rounded,
              },
              onChanged: settings.setDesktopTextAlignX,
            ),
            LyricColorRow(
              key: const Key('desktopColorShadowRow'),
              icon: Icons.blur_on_rounded,
              title: l10n.lyricsDesktopColorShadow,
              source: settings.desktopShadowColorSource,
              customColor: settings.desktopShadowColor,
              scheme: scheme,
              onSourceChanged: settings.setDesktopShadowColorSource,
              onCustomColorChanged: settings.setDesktopShadowColor,
            ),
            SettingsSwitchTile(
              icon: Icons.ac_unit_rounded,
              title: l10n.lyricsDesktopFreeze,
              subtitle: '',
              value: settings.desktopFreezeOnScreenOff,
              onChanged: settings.setDesktopFreezeOnScreenOff,
            ),
            SettingsSwitchTile(
              icon: Icons.animation_rounded,
              title: l10n.lyricsDesktopAnimation,
              subtitle: '',
              value: settings.desktopShowToggleAnimation,
              onChanged: settings.setDesktopShowToggleAnimation,
            ),
            SettingsChoiceRow<LyricsPauseBehavior>(
              icon: Icons.pause_rounded,
              title: l10n.lyricsDesktopPauseBehavior,
              // 整窗隐藏时回退策略不生效：置灰并说明原因（值保留，关掉开关即恢复可点）。
              subtitle: settings.desktopHideOnPause
                  ? l10n.lyricsDesktopPauseFallbackOverridden
                  : null,
              enabled: !settings.desktopHideOnPause,
              value: settings.desktopPauseBehavior,
              options: [
                (LyricsPauseBehavior.keep, l10n.lyricsBehaviorKeep),
                (LyricsPauseBehavior.title, l10n.lyricsBehaviorTitle),
                (LyricsPauseBehavior.clear, l10n.lyricsBehaviorClear),
              ],
              onChanged: settings.setDesktopPauseBehavior,
            ),
            SettingsChoiceRow<DesktopNoLyricsBehavior>(
              icon: Icons.music_off_rounded,
              title: l10n.lyricsDesktopNoLyrics,
              value: settings.desktopNoLyricsBehavior,
              options: [
                (DesktopNoLyricsBehavior.title, l10n.lyricsBehaviorTitle),
                (DesktopNoLyricsBehavior.hide, l10n.lyricsDisplayUnsyncedHide),
              ],
              onChanged: settings.setDesktopNoLyricsBehavior,
            ),
          ],
        ),
        const SizedBox(height: kSettingsSectionSpacing),
        SettingsSectionCard(
          title: l10n.lyricsDesktopControlsSection,
          children: [
            _controlSwitch(
              l10n.lyricsControlPlayPause,
              Icons.play_arrow_rounded,
              DesktopControlKeys.playPause,
              settings,
            ),
            _controlSwitch(
              l10n.lyricsControlPrevious,
              Icons.skip_previous_rounded,
              DesktopControlKeys.previous,
              settings,
            ),
            _controlSwitch(
              l10n.lyricsControlNext,
              Icons.skip_next_rounded,
              DesktopControlKeys.next,
              settings,
            ),
            _controlSwitch(
              l10n.lyricsControlTranslation,
              Icons.translate_rounded,
              DesktopControlKeys.translation,
              settings,
            ),
            _controlSwitch(
              l10n.lyricsControlLock,
              Icons.lock_rounded,
              DesktopControlKeys.lock,
              settings,
            ),
            _controlSwitch(
              l10n.lyricsControlClose,
              Icons.close_rounded,
              DesktopControlKeys.close,
              settings,
            ),
          ],
        ),
      ],
    );
  }

  /// 控制条按钮可见性开关（键 → 配置字段一一对应）。
  Widget _controlSwitch(
    String title,
    IconData icon,
    String key,
    LyricsDisplaySettings settings,
  ) {
    return SettingsSwitchTile(
      icon: icon,
      title: title,
      subtitle: '',
      value: settings.desktopControls[key] ?? true,
      onChanged: (value) => settings.setDesktopControlVisible(key, value),
    );
  }
}
