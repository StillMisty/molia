/// 桌面歌词颜色行：显示解析后的颜色，点开「颜色来源」面板。
///
/// 主设置页（播放/未播放颜色）与高级页（阴影颜色）共用同一套解析与面板，
/// 避免两份颜色来源清单漂移。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../services/lyrics_display/lyric_color_resolver.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../utils/color_hex.dart';
import '../../widgets/app_color_picker.dart';
import '../../widgets/settings/settings_tiles.dart';

class LyricColorRow extends StatelessWidget {
  const LyricColorRow({
    super.key,
    required this.icon,
    required this.title,
    required this.source,
    required this.customColor,
    required this.scheme,
    required this.onSourceChanged,
    required this.onCustomColorChanged,
  });

  final IconData icon;
  final String title;
  final LyricColorSource source;
  final int customColor;
  final ColorScheme scheme;
  final Future<void> Function(LyricColorSource) onSourceChanged;
  final Future<void> Function(int) onCustomColorChanged;

  @override
  Widget build(BuildContext context) {
    return SettingsColorValueTile(
      icon: icon,
      title: title,
      colorArgb: resolveLyricColor(source, customColor, scheme),
      onTap: () => showLyricColorSourcePanel(
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
}

/// 颜色选择面板：选来源即生效。
///
/// - 选主题角色：直接写入来源并关面板；
/// - 选自定义：先关面板再打开任意取色器（HSV + Hex + 透明度），
///   确认后写入「自定义」来源与颜色；取消不改任何配置。
Future<void> showLyricColorSourcePanel(
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
