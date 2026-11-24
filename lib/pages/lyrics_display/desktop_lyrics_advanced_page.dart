import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/app_providers.dart';
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
class DesktopLyricsAdvancedPage extends ConsumerWidget {
  const DesktopLyricsAdvancedPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.watch(lyricsDisplaySettingsProvider);
    final controller = ref.read(lyricsDisplaySettingsControllerProvider);
    final theme = ref.watch(themeProvider);
    final scheme = resolveSurfaceScheme(
      settings.desktopSchemeSource,
      appScheme: theme.colorScheme,
      artworkScheme: theme.artworkColorScheme,
    );
    return SettingsSubPage(
      title: l10n.lyricsDesktopAdvancedTitle,
      children: [
        SettingsSectionCard(
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
              onChanged: (value) => controller?.setDesktopTextAlignX(value),
            ),
            LyricColorRow(
              key: const Key('desktopColorShadowRow'),
              icon: Icons.blur_on_rounded,
              title: l10n.lyricsDesktopColorShadow,
              source: settings.desktopShadowColorSource,
              customColor: settings.desktopShadowColor,
              scheme: scheme,
              onSourceChanged: (value) async {
                await controller?.setDesktopShadowColorSource(value);
              },
              onCustomColorChanged: (value) async {
                await controller?.setDesktopShadowColor(value);
              },
            ),
            SettingsSwitchTile(
              icon: Icons.ac_unit_rounded,
              title: l10n.lyricsDesktopFreeze,
              subtitle: '',
              value: settings.desktopFreezeOnScreenOff,
              onChanged: (value) =>
                  controller?.setDesktopFreezeOnScreenOff(value),
            ),
            SettingsSwitchTile(
              icon: Icons.animation_rounded,
              title: l10n.lyricsDesktopAnimation,
              subtitle: '',
              value: settings.desktopShowToggleAnimation,
              onChanged: (value) =>
                  controller?.setDesktopShowToggleAnimation(value),
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
              onChanged: (value) => controller?.setDesktopPauseBehavior(value),
            ),
            SettingsChoiceRow<DesktopNoLyricsBehavior>(
              icon: Icons.music_off_rounded,
              title: l10n.lyricsDesktopNoLyrics,
              value: settings.desktopNoLyricsBehavior,
              options: [
                (DesktopNoLyricsBehavior.title, l10n.lyricsBehaviorTitle),
                (DesktopNoLyricsBehavior.hide, l10n.lyricsDisplayUnsyncedHide),
              ],
              onChanged: (value) =>
                  controller?.setDesktopNoLyricsBehavior(value),
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
              controller,
            ),
            _controlSwitch(
              l10n.lyricsControlPrevious,
              Icons.skip_previous_rounded,
              DesktopControlKeys.previous,
              settings,
              controller,
            ),
            _controlSwitch(
              l10n.lyricsControlNext,
              Icons.skip_next_rounded,
              DesktopControlKeys.next,
              settings,
              controller,
            ),
            _controlSwitch(
              l10n.lyricsControlTranslation,
              Icons.translate_rounded,
              DesktopControlKeys.translation,
              settings,
              controller,
            ),
            _controlSwitch(
              l10n.lyricsControlLock,
              Icons.lock_rounded,
              DesktopControlKeys.lock,
              settings,
              controller,
            ),
            _controlSwitch(
              l10n.lyricsControlClose,
              Icons.close_rounded,
              DesktopControlKeys.close,
              settings,
              controller,
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
    LyricsDisplaySettingsState settings,
    LyricsDisplaySettings? controller,
  ) {
    return SettingsSwitchTile(
      icon: icon,
      title: title,
      subtitle: '',
      value: settings.desktopControls[key] ?? true,
      onChanged: (value) => controller?.setDesktopControlVisible(key, value),
    );
  }
}
