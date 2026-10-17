import 'dart:async';
import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/lyrics_display_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/lyrics_display/lyric_color_resolver.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../services/lyrics_display/lyrics_output.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/scheme_builder.dart';
import '../../utils/color_hex.dart';
import '../../widgets/app_color_picker.dart';
import '../../widgets/settings/settings_tiles.dart';
import 'lyrics_shared_display_section.dart';

/// 桌面歌词子页：外观与配色（含开关与权限）、共享展示项、行为与控制条。
///
/// 颜色解析与悬浮窗下发同源：先按「取色来源」解析出方案（应用主题 /
/// 当前曲目封面），再用 [resolveLyricColor] 得到角色色或自定义色；
/// 主题 / 封面变化时本页与悬浮窗一起刷新。
class DesktopLyricsSettingsPage extends StatelessWidget {
  const DesktopLyricsSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<LyricsDisplaySettings>();
    final themeProvider = context.watch<ThemeProvider>();
    final display = context.watch<LyricsDisplayProvider>();
    final capability = display.capabilityOf(LyricsOutputIds.desktop);
    final scheme = resolveSurfaceScheme(
      settings.desktopSchemeSource,
      appScheme: themeProvider.colorScheme,
      artworkScheme: themeProvider.artworkColorScheme,
    );

    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.lyricsDesktopTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          SettingsSectionCard(
            title: l10n.lyricsDesktopTitle,
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
                    await display.requestDesktopOverlayPermission();
                    return;
                  }
                  await settings.setDesktopEnabled(value);
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
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                      ),
                      M3EButton.icon(
                        style: M3EButtonStyle.text,
                        onPressed: display.requestDesktopOverlayPermission,
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
                onChanged: (value) =>
                    settings.setDesktopFontSize(value.roundToDouble()),
              ),
              SettingsSliderRow(
                icon: Icons.opacity_rounded,
                title: l10n.lyricsDesktopOpacity,
                valueLabel: '${(settings.desktopOpacity * 100).round()}%',
                value: settings.desktopOpacity * 100,
                min: LyricsDisplaySettings.opacityRange.first * 100,
                max: LyricsDisplaySettings.opacityRange.last * 100,
                divisions: 16,
                onChanged: (value) =>
                    settings.setDesktopOpacity((value / 100).clamp(0.2, 1.0)),
              ),
              SettingsSliderRow(
                icon: Icons.width_normal_rounded,
                title: l10n.lyricsDesktopWidth,
                valueLabel: '${settings.desktopWidthPercent.round()}%',
                value: settings.desktopWidthPercent,
                min: LyricsDisplaySettings.widthRange.first,
                max: LyricsDisplaySettings.widthRange.last,
                divisions: 12,
                onChanged: (value) => settings.setDesktopWidthPercent(value),
              ),
              // 显示行数（默认 1 = 只显示当前行；旧的「仅显示当前行」开关已合并到这里）。
              // 保持 dropdown：选项多、文案是纯数字，下拉比分段更省横向空间。
              SettingsDropdownRow<int>(
                icon: Icons.format_list_numbered_rounded,
                title: l10n.lyricsDesktopMaxLines,
                value: settings.desktopMaxLines,
                options: [
                  for (final value in const [1, 2, 3, 4, 5])
                    (value, '$value'),
                ],
                onChanged: settings.setDesktopMaxLines,
              ),
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
              // 取色来源：决定三行「跟随主题角色」用哪套方案（应用主题 /
              // 当前曲目封面）；自定义行不受影响。
              SettingsChoiceRow<SurfaceColorSource>(
                icon: Icons.palette_rounded,
                title: l10n.lyricsDesktopSchemeSource,
                value: settings.desktopSchemeSource,
                options: [
                  (
                    SurfaceColorSource.appTheme,
                    l10n.lyricsDesktopSchemeAppTheme,
                  ),
                  (
                    SurfaceColorSource.artwork,
                    l10n.lyricsDesktopSchemeArtwork,
                  ),
                ],
                onChanged: settings.setDesktopSchemeSource,
              ),
              _colorRow(
                context,
                rowKey: const Key('desktopColorPlayedRow'),
                icon: Icons.text_fields_rounded,
                title: l10n.lyricsDesktopColorPlayed,
                source: settings.desktopPlayedColorSource,
                customColor: settings.desktopPlayedColor,
                scheme: scheme,
                onSourceChanged: settings.setDesktopPlayedColorSource,
                onCustomColorChanged: settings.setDesktopPlayedColor,
              ),
              _colorRow(
                context,
                rowKey: const Key('desktopColorUnplayedRow'),
                icon: Icons.text_fields_rounded,
                title: l10n.lyricsDesktopColorUnplayed,
                source: settings.desktopUnplayedColorSource,
                customColor: settings.desktopUnplayedColor,
                scheme: scheme,
                onSourceChanged: settings.setDesktopUnplayedColorSource,
                onCustomColorChanged: settings.setDesktopUnplayedColor,
              ),
              _colorRow(
                context,
                rowKey: const Key('desktopColorShadowRow'),
                icon: Icons.blur_on_rounded,
                title: l10n.lyricsDesktopColorShadow,
                source: settings.desktopShadowColorSource,
                customColor: settings.desktopShadowColor,
                scheme: scheme,
                onSourceChanged: settings.setDesktopShadowColorSource,
                onCustomColorChanged: settings.setDesktopShadowColor,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: Text(
                  l10n.lyricsDesktopColorThemeHint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: kSettingsSectionSpacing),
          LyricsSharedDisplaySection(title: l10n.lyricsSharedDisplaySection),
          const SizedBox(height: kSettingsSectionSpacing),
          SettingsSectionCard(
            title: l10n.lyricsDesktopBehaviorSection,
            children: [
              SettingsSwitchTile(
                icon: Icons.lock_rounded,
                title: l10n.lyricsDesktopLock,
                subtitle: '',
                value: settings.desktopLock,
                onChanged: settings.setDesktopLock,
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
                  (
                    DesktopScrollMode.constant,
                    l10n.lyricsDesktopScrollConstant,
                  ),
                ],
                onChanged: settings.setDesktopScrollMode,
              ),
              SettingsSwitchTile(
                icon: Icons.visibility_off_rounded,
                title: l10n.lyricsDesktopHideOnPause,
                subtitle: l10n.lyricsDesktopHideOnPauseSubtitle,
                value: settings.desktopHideOnPause,
                onChanged: settings.setDesktopHideOnPause,
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
                  (
                    DesktopNoLyricsBehavior.hide,
                    l10n.lyricsDisplayUnsyncedHide,
                  ),
                ],
                onChanged: settings.setDesktopNoLyricsBehavior,
              ),
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
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: M3EButton.icon(
                  style: M3EButtonStyle.tonal,
                  onPressed: display.resetDesktopPosition,
                  icon: const Icon(Icons.center_focus_strong_rounded),
                  label: Text(l10n.lyricsDesktopResetPosition),
                ),
              ),
            ],
          ),
        ],
      ),
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

  /// 颜色行：显示当前解析出的颜色，点开「颜色选择面板」。
  Widget _colorRow(
    BuildContext context, {
    required Key rowKey,
    required IconData icon,
    required String title,
    required LyricColorSource source,
    required int customColor,
    required ColorScheme scheme,
    required Future<void> Function(LyricColorSource) onSourceChanged,
    required Future<void> Function(int) onCustomColorChanged,
  }) {
    return SettingsColorValueTile(
      key: rowKey,
      icon: icon,
      title: title,
      colorArgb: resolveLyricColor(source, customColor, scheme),
      onTap: () => _showColorSourcePanel(
        context,
        title: title,
        selected: source,
        customColor: customColor,
        scheme: scheme,
        onSourceChanged: onSourceChanged,
        onCustomColorChanged: onCustomColorChanged,
      ),
    );
  }

  /// 颜色选择面板：选来源即生效。
  ///
  /// - 选主题角色：直接写入来源并关面板；
  /// - 选自定义：先关面板再打开任意取色器（HSV + Hex + 透明度），
  ///   确认后写入「自定义」来源与颜色；取消不改任何配置。
  Future<void> _showColorSourcePanel(
    BuildContext context, {
    required String title,
    required LyricColorSource selected,
    required int customColor,
    required ColorScheme scheme,
    required Future<void> Function(LyricColorSource) onSourceChanged,
    required Future<void> Function(int) onCustomColorChanged,
  }) {
    final l10n = AppLocalizations.of(context)!;
    // M3EDialog.show 固定把 dialog 推入 root navigator，关闭也必须定向 root。
    final navigator = Navigator.of(context, rootNavigator: true);
    Future<void> apply(LyricColorSource source) async {
      if (source != LyricColorSource.custom) {
        await onSourceChanged(source);
        navigator.pop();
        return;
      }
      navigator.pop();
      final picked = await showAppColorPicker(
        context,
        initialColor: customColor,
        withAlpha: true,
      );
      if (picked == null) return;
      await onSourceChanged(LyricColorSource.custom);
      await onCustomColorChanged(picked);
    }

    return M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: title,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: M3ERadioGroup<LyricColorSource>(
            groupValue: selected,
            onChanged: (source) => unawaited(apply(source)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final source in LyricColorSource.values)
                  _ColorSourceOption(
                    source: source,
                    groupValue: selected,
                    argb: resolveLyricColor(source, customColor, scheme),
                    onSelected: (value) => unawaited(apply(value)),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(),
            child: Text(l10n.cancelButton),
          ),
        ],
      ),
    );
  }

  /// 样式预览：用与悬浮窗相同的配置渲染一行示例，调完即所见。
  Widget _previewCard(
    BuildContext context,
    AppLocalizations l10n,
    LyricsDisplaySettings settings,
    ColorScheme scheme,
  ) {
    final fontSize = math.min(settings.desktopFontSize, 28.0);
    final played = Color(resolveLyricColor(
      settings.desktopPlayedColorSource,
      settings.desktopPlayedColor,
      scheme,
    ));
    final unplayed = Color(resolveLyricColor(
      settings.desktopUnplayedColorSource,
      settings.desktopUnplayedColor,
      scheme,
    ));
    final shadow = Color(resolveLyricColor(
      settings.desktopShadowColorSource,
      settings.desktopShadowColor,
      scheme,
    ));
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
              borderRadius: BorderRadius.circular(12),
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

/// 颜色来源候选项：radio + 色块 / 名称 / hex，整行可点。
///
/// 不复用 `M3ERadio.label`：label 挂在外层 `mainAxisSize.min` 的 Row 上，
/// 非 flex 子项拿到无界宽度约束，内部放不了 `Expanded`（hex 无法右对齐）；
/// 这里把候选项做成「radio + Expanded 可点标签区」，视觉与交互等价。
class _ColorSourceOption extends StatelessWidget {
  const _ColorSourceOption({
    required this.source,
    required this.groupValue,
    required this.argb,
    required this.onSelected,
  });

  final LyricColorSource source;
  final LyricColorSource groupValue;
  final int argb;
  final ValueChanged<LyricColorSource> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final m3e = M3ETheme.of(context);
    final name = _colorSourceLabel(l10n, source);
    final hex = colorHexLabel(argb, withAlpha: (argb >> 24) & 0xFF != 0xFF);
    return Row(
      children: [
        M3ERadio<LyricColorSource>(
          value: source,
          groupValue: groupValue,
          onChanged: onSelected,
        ),
        Expanded(
          child: M3ETappable(
            onTap: () => onSelected(source),
            // radio 自身是键盘 Tab 停靠点，标签区只承担指针点击；
            // 语义上的「选中」由 radio 承担（标签区再报一次会让
            // Semantics 认为 radio group 里有多个选中项）。
            focusable: false,
            semanticLabel: '$name, $hex',
            semanticButton: false,
            builder: (context, _) => Row(
              children: [
                SettingsColorSwatch(color: Color(argb), size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    style: m3e.typeScale.bodyLarge.copyWith(
                      color: m3e.colorScheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  hex,
                  style: m3e.typeScale.bodySmall.copyWith(
                    color: m3e.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String _colorSourceLabel(AppLocalizations l10n, LyricColorSource source) =>
    switch (source) {
      LyricColorSource.custom => l10n.lyricsColorSourceCustom,
      LyricColorSource.primary => l10n.lyricsColorSourcePrimary,
      LyricColorSource.secondary => l10n.lyricsColorSourceSecondary,
      LyricColorSource.tertiary => l10n.lyricsColorSourceTertiary,
      LyricColorSource.onSurface => l10n.lyricsColorSourceOnSurface,
      LyricColorSource.onSurfaceVariant =>
        l10n.lyricsColorSourceOnSurfaceVariant,
      LyricColorSource.surface => l10n.lyricsColorSourceSurface,
    };
