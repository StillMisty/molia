/// 海报样式弹层内容：字体 / 取色来源 / 封面 / 自定义色。
///
/// 歌词海报把常驻底栏的样式行收进「样式」弹层，底栏只留一个主操作与一个
/// 溢出菜单；这里只负责展示与回调，状态仍由海报页持有并负责重新生成。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../services/poster_color_store.dart';
import '../theme/m3e_context.dart';
import 'simple_modal_body.dart';

/// 海报样式弹层。
class PosterStyleSheet extends StatelessWidget {
  const PosterStyleSheet({
    super.key,
    required this.fontLabel,
    required this.fontValue,
    required this.onPickFont,
    required this.colorSource,
    required this.hasArtwork,
    required this.onColorSourceChanged,
    required this.customColorLabel,
    required this.customColorHex,
    required this.customColor,
    required this.onPickCustomColor,
    required this.coverLabel,
    required this.coverValue,
    this.coverThumbnail,
    this.onPickCover,
  });

  final String fontLabel;
  final String fontValue;
  final VoidCallback onPickFont;

  final PosterColorSource colorSource;
  final bool hasArtwork;
  final ValueChanged<PosterColorSource> onColorSourceChanged;

  final String customColorLabel;
  final String customColorHex;
  final int customColor;
  final VoidCallback onPickCustomColor;

  final String coverLabel;
  final String coverValue;
  final Widget? coverThumbnail;
  final VoidCallback? onPickCover;

  /// 值控件统一宽度：右值成一列，行与行之间不参差。
  static const double _valueWidth = 190;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: SimpleModalBody(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          _settingRow(
            label: fontLabel,
            value: M3EButton(
              key: const Key('posterStyleFont'),
              style: M3EButtonStyle.text,
              onPressed: onPickFont,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      fontValue,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.expand_more_rounded, size: 18),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          _settingRow(
            label: l10n.posterColorSource,
            value: M3EDropdownMenu<PosterColorSource>(
              items: [
                M3EDropdownItem<PosterColorSource>(
                  label: l10n.posterColorSourceAppTheme,
                  value: PosterColorSource.appTheme,
                  selected: colorSource == PosterColorSource.appTheme,
                ),
                M3EDropdownItem<PosterColorSource>(
                  label: l10n.posterColorSourceArtwork,
                  value: PosterColorSource.artwork,
                  selected: colorSource == PosterColorSource.artwork,
                  disabled: !hasArtwork,
                ),
                M3EDropdownItem<PosterColorSource>(
                  label: l10n.posterColorSourceCustom,
                  value: PosterColorSource.custom,
                  selected: colorSource == PosterColorSource.custom,
                ),
              ],
              singleSelect: true,
              showChipAnimation: false,
              onSelectionChanged: (items) {
                if (items.isNotEmpty) onColorSourceChanged(items.first.value);
              },
            ),
          ),
          const SizedBox(height: 4),
          _settingRow(
            label: coverLabel,
            value: M3EButton(
              key: const Key('posterStyleCover'),
              style: M3EButtonStyle.text,
              onPressed: onPickCover,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (coverThumbnail != null) ...[
                    coverThumbnail!,
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      coverValue,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.expand_more_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (colorSource == PosterColorSource.custom) ...[
            const SizedBox(height: 4),
            _settingRow(
              label: customColorLabel,
              value: M3EButton(
                key: const Key('posterStyleCustomColor'),
                style: M3EButtonStyle.text,
                onPressed: onPickCustomColor,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(customColor),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(customColorHex, style: context.typeScale.bodyMedium),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _settingRow({required String label, required Widget value}) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        SizedBox(
          width: _valueWidth,
          child: Align(alignment: Alignment.centerRight, child: value),
        ),
      ],
    );
  }
}
