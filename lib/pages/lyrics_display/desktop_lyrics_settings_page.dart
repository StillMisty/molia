import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/app_providers.dart';
import '../../providers/theme_provider.dart';
import '../../services/lyrics_display/lyric_color_resolver.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../services/lyrics_display/lyrics_output.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/m3e_context.dart';
import '../../theme/scheme_builder.dart';
import '../../widgets/settings/settings_subpage.dart';
import '../../widgets/settings/settings_tiles.dart';
import 'desktop_lyrics_advanced_page.dart';
import 'lyric_color_row.dart';

/// 桌面歌词子页：外观与配色（含开关与权限）、共享展示项、行为与控制条。
///
/// 颜色解析与悬浮窗下发同源：先按「取色来源」解析出方案（应用主题 /
/// 当前曲目封面），再用 [resolveLyricColor] 得到角色色或自定义色；
/// 主题 / 封面变化时本页与悬浮窗一起刷新。
class DesktopLyricsSettingsPage extends ConsumerWidget {
  const DesktopLyricsSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.watch(lyricsDisplaySettingsProvider);
    final controller = ref.read(lyricsDisplaySettingsControllerProvider);
    final theme = ref.watch(themeProvider);
    final display = ref.watch(lyricsDisplayProvider);
    final displayController = ref.read(lyricsDisplayControllerProvider);
    // 滑杆松手立即落盘；控制器未接线（独立预览）时保持无操作。
    Future<void> flushSettings() =>
        controller?.flushPersistence() ?? Future<void>.value();
    final capability = display.capabilityOf(LyricsOutputIds.desktop);
    final scheme = resolveSurfaceScheme(
      settings.desktopSchemeSource,
      appScheme: theme.colorScheme,
      artworkScheme: theme.artworkColorScheme,
    );

    return SettingsSubPage(
      title: l10n.lyricsDesktopTitle,
      children: [
        SettingsSectionCard(
          children: [
            SettingsSwitchTile(
              icon: Icons.picture_in_picture_alt_rounded,
              title: l10n.lyricsDesktopEnable,
              subtitle: l10n.lyricsDesktopEnableSubtitle,
              value: settings.desktopEnabled,
              onChanged: (value) async {
                if (value &&
                    capability == LyricsOutputCapability.needsPermission) {
                  // 未授权：不假装开启，直接引导到系统授权页；
                  // 授权返回后由设置首屏的 lifecycle 监听复查能力。
                  await displayController?.requestDesktopOverlayPermission();
                  return;
                }
                await controller?.setDesktopEnabled(value);
              },
            ),
            if (capability == LyricsOutputCapability.needsPermission)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: AppSemanticColors.of(context).warning,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        l10n.lyricsDesktopPermissionNeeded,
                        style: context.typeScale.bodySmall.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    M3EButton.icon(
                      style: M3EButtonStyle.text,
                      onPressed:
                          displayController?.requestDesktopOverlayPermission,
                      icon: const Icon(Icons.lock_open_rounded, size: 18),
                      label: Text(l10n.lyricsDesktopPermissionGrant),
                    ),
                  ],
                ),
              ),
            _previewCard(context, l10n, settings, scheme),
            SettingsSliderRow(
              icon: Icons.format_size_rounded,
              title: l10n.lyricsDesktopFontSize,
              valueLabel: settings.desktopFontSize.round().toString(),
              value: settings.desktopFontSize,
              min: LyricsDisplaySettings.fontSizeRange.first,
              max: LyricsDisplaySettings.fontSizeRange.last,
              divisions: 36,
              onChanged: (value) => controller?.setDesktopFontSize(
                value.roundToDouble(),
                persist: false,
              ),
              onChangeEnd: (_) => unawaited(flushSettings()),
            ),
            SettingsSliderRow(
              icon: Icons.opacity_rounded,
              title: l10n.lyricsDesktopOpacity,
              valueLabel: '${(settings.desktopOpacity * 100).round()}%',
              value: settings.desktopOpacity * 100,
              min: LyricsDisplaySettings.opacityRange.first * 100,
              max: LyricsDisplaySettings.opacityRange.last * 100,
              divisions: 16,
              onChanged: (value) => controller?.setDesktopOpacity(
                (value / 100).clamp(0.2, 1.0),
                persist: false,
              ),
              onChangeEnd: (_) => unawaited(flushSettings()),
            ),
            SettingsSliderRow(
              icon: Icons.width_normal_rounded,
              title: l10n.lyricsDesktopWidth,
              valueLabel: '${settings.desktopWidthPercent.round()}%',
              value: settings.desktopWidthPercent,
              min: LyricsDisplaySettings.widthRange.first,
              max: LyricsDisplaySettings.widthRange.last,
              divisions: 12,
              onChanged: (value) =>
                  controller?.setDesktopWidthPercent(value, persist: false),
              onChangeEnd: (_) => unawaited(flushSettings()),
            ),
            // 显示行数（默认 1 = 只显示当前行）。
            // 保持 dropdown：选项多、文案是纯数字，下拉比分段更省横向空间。
            SettingsDropdownRow<int>(
              icon: Icons.format_list_numbered_rounded,
              title: l10n.lyricsDesktopMaxLines,
              value: settings.desktopMaxLines,
              options: [
                for (final value in const [1, 2, 3, 4, 5]) (value, '$value'),
              ],
              onChanged: (value) => controller?.setDesktopMaxLines(value),
            ),
            // 取色来源：决定颜色行「跟随主题角色」用哪套方案（应用主题 /
            // 当前曲目封面）；自定义行不受影响。
            SettingsChoiceRow<SurfaceColorSource>(
              icon: Icons.palette_rounded,
              title: l10n.lyricsDesktopSchemeSource,
              value: settings.desktopSchemeSource,
              options: [
                (SurfaceColorSource.appTheme, l10n.lyricsDesktopSchemeAppTheme),
                (SurfaceColorSource.artwork, l10n.lyricsDesktopSchemeArtwork),
              ],
              onChanged: (value) => controller?.setDesktopSchemeSource(value),
            ),
            LyricColorRow(
              key: const Key('desktopColorPlayedRow'),
              icon: Icons.text_fields_rounded,
              title: l10n.lyricsDesktopColorPlayed,
              source: settings.desktopPlayedColorSource,
              customColor: settings.desktopPlayedColor,
              scheme: scheme,
              onSourceChanged: (value) async {
                await controller?.setDesktopPlayedColorSource(value);
              },
              onCustomColorChanged: (value) async {
                await controller?.setDesktopPlayedColor(value);
              },
            ),
            LyricColorRow(
              key: const Key('desktopColorUnplayedRow'),
              icon: Icons.text_fields_rounded,
              title: l10n.lyricsDesktopColorUnplayed,
              source: settings.desktopUnplayedColorSource,
              customColor: settings.desktopUnplayedColor,
              scheme: scheme,
              onSourceChanged: (value) async {
                await controller?.setDesktopUnplayedColorSource(value);
              },
              onCustomColorChanged: (value) async {
                await controller?.setDesktopUnplayedColor(value);
              },
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text(
                l10n.lyricsDesktopColorThemeHint,
                style: context.typeScale.bodySmall.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: kSettingsSectionSpacing),
        SettingsSectionCard(
          title: l10n.lyricsDesktopBehaviorSection,
          children: [
            SettingsSwitchTile(
              icon: Icons.lock_rounded,
              title: l10n.lyricsDesktopLock,
              subtitle: '',
              value: settings.desktopLock,
              onChanged: (value) => controller?.setDesktopLock(value),
            ),
            SettingsChoiceRow<DesktopScrollMode>(
              key: const Key('desktopScrollModeRow'),
              icon: Icons.keyboard_double_arrow_right_rounded,
              title: l10n.lyricsDesktopScrollMode,
              subtitle: l10n.lyricsDesktopScrollModeSubtitle,
              value: settings.desktopScrollMode,
              options: [
                (
                  DesktopScrollMode.followSinging,
                  l10n.lyricsDesktopScrollFollow,
                ),
                (DesktopScrollMode.constant, l10n.lyricsDesktopScrollConstant),
              ],
              onChanged: (value) => controller?.setDesktopScrollMode(value),
            ),
            SettingsSwitchTile(
              icon: Icons.visibility_off_rounded,
              title: l10n.lyricsDesktopHideOnPause,
              subtitle: l10n.lyricsDesktopHideOnPauseSubtitle,
              value: settings.desktopHideOnPause,
              onChanged: (value) => controller?.setDesktopHideOnPause(value),
            ),
            SettingsNavTile(
              key: const Key('lyricsDesktopAdvancedItem'),
              icon: Icons.tune_rounded,
              title: l10n.lyricsDesktopAdvancedTitle,
              subtitle: l10n.lyricsDesktopAdvancedSubtitle,
              onTap: () => openSettingsSubPage(
                context,
                const DesktopLyricsAdvancedPage(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: M3EButton.icon(
                style: M3EButtonStyle.tonal,
                onPressed: displayController?.resetDesktopPosition,
                icon: const Icon(Icons.center_focus_strong_rounded),
                label: Text(l10n.lyricsDesktopResetPosition),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 样式预览：用与悬浮窗相同的配置渲染一行示例，调完即所见。
  Widget _previewCard(
    BuildContext context,
    AppLocalizations l10n,
    LyricsDisplaySettingsState settings,
    ColorScheme scheme,
  ) {
    final fontSize = math.min(settings.desktopFontSize, 28.0);
    final played = Color(
      resolveLyricColor(
        settings.desktopPlayedColorSource,
        settings.desktopPlayedColor,
        scheme,
      ),
    );
    final unplayed = Color(
      resolveLyricColor(
        settings.desktopUnplayedColorSource,
        settings.desktopUnplayedColor,
        scheme,
      ),
    );
    final shadow = Color(
      resolveLyricColor(
        settings.desktopShadowColorSource,
        settings.desktopShadowColor,
        scheme,
      ),
    );
    final previewLines = <Widget>[
      Text(
        l10n.lyricsDesktopPreviewLine,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: played.withValues(alpha: settings.desktopOpacity),
          fontSize: fontSize,
          shadows: [
            Shadow(color: shadow, blurRadius: 2, offset: const Offset(0, 1)),
          ],
        ),
      ),
    ];
    if (settings.translationEnabled) {
      previewLines.add(
        Text(
          l10n.lyricsDesktopPreviewTranslation,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: unplayed.withValues(alpha: settings.desktopOpacity),
            fontSize: fontSize * 0.8,
            shadows: [
              Shadow(color: shadow, blurRadius: 2, offset: const Offset(0, 1)),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.lyricsDesktopPreview),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            decoration: BoxDecoration(
              // 预览画布用应用表面；文字颜色跟随「取色来源」解析出的方案，
              // 与悬浮窗实际下发一致。
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: M3EShapes.radiusMedium,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: previewLines,
            ),
          ),
        ],
      ),
    );
  }
}
