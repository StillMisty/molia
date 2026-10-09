import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';

/// 解析 Hex 颜色（输入框与单测共用）。
///
/// - 接受 `#RRGGBB` / `#AARRGGBB`（`#` 可省略，大小写不限）；
/// - 6 位时保留 [keepAlpha]（0..1）；8 位（AARRGGBB）使用输入中的透明度；
/// - 非法输入返回 null。
@visibleForTesting
int? parseColorHex(String text, {required double keepAlpha}) {
  var value = text.trim().replaceFirst('#', '');
  if (value.isEmpty) return null;
  if (value.length == 3) {
    value = value.split('').map((char) => '$char$char').join();
  }
  if (value.length != 6 && value.length != 8) return null;
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) return null;
  final rgb = int.parse(value.substring(value.length - 6), radix: 16);
  final alpha = value.length == 8
      ? int.parse(value.substring(0, 2), radix: 16)
      : (keepAlpha.clamp(0.0, 1.0) * 255).round();
  return (alpha << 24) | rgb;
}

/// 任意颜色选择器（HSV 滑杆 + Hex 输入 + 可选透明度）。
///
/// 主题种子色与桌面歌词颜色共用；返回 ARGB int，取消返回 null。
Future<int?> showAppColorPicker(
  BuildContext context, {
  required int initialColor,
  bool withAlpha = false,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final selected = ValueNotifier<int>(initialColor);
  final width = math.min(MediaQuery.of(context).size.width * 0.9, 420.0);
  final result = await M3EDialog.show<int>(
    context,
    dialog: M3EDialog(
      title: l10n.colorPickerTitle,
      content: SizedBox(
        width: width,
        child: _ColorPickerContent(
          initialColor: initialColor,
          withAlpha: withAlpha,
          selected: selected,
        ),
      ),
      actions: [
        M3EButton.text(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancelButton),
        ),
        M3EButton.filled(
          onPressed: () => Navigator.pop(context, selected.value),
          child: Text(l10n.saveChanges),
        ),
      ],
    ),
  );
  selected.dispose();
  return result;
}

class _ColorPickerContent extends StatefulWidget {
  const _ColorPickerContent({
    required this.initialColor,
    required this.withAlpha,
    required this.selected,
  });

  final int initialColor;
  final bool withAlpha;
  final ValueNotifier<int> selected;

  @override
  State<_ColorPickerContent> createState() => _ColorPickerContentState();
}

class _ColorPickerContentState extends State<_ColorPickerContent> {
  late HSVColor _hsv;
  late double _alpha;
  late final TextEditingController _hexController;
  String? _error;

  @override
  void initState() {
    super.initState();
    final color = Color(widget.initialColor);
    _hsv = HSVColor.fromColor(color);
    _alpha = widget.withAlpha ? color.a : 1.0;
    _hexController = TextEditingController(text: _hexText());
    _emit();
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  Color get _color => _hsv.toColor().withValues(alpha: _alpha);

  String _hexText() {
    final argb = _color.toARGB32();
    final hex = argb.toRadixString(16).padLeft(8, '0').toUpperCase();
    return widget.withAlpha ? '#$hex' : '#${hex.substring(2)}';
  }

  void _emit() => widget.selected.value = _color.toARGB32();

  /// 滑杆改动：同步 Hex 文本（用户不在输入框中）。
  void _setHsv(HSVColor hsv, {double? alpha}) {
    setState(() {
      _hsv = hsv;
      if (alpha != null) _alpha = alpha;
      _hexController.text = _hexText();
      _error = null;
    });
    _emit();
  }

  /// Hex 输入：实时解析（不重写输入框，避免光标跳动）。
  void _onHexChanged(String text) {
    if (text.trim().isEmpty) {
      setState(() => _error = null);
      return;
    }
    final parsed = parseColorHex(
      text,
      keepAlpha: widget.withAlpha ? _alpha : 1.0,
    );
    if (parsed == null) {
      setState(() => _error = AppLocalizations.of(context)!.colorPickerInvalid);
      return;
    }
    final color = Color(parsed);
    setState(() {
      _hsv = HSVColor.fromColor(color);
      _alpha = widget.withAlpha ? color.a : 1.0;
      _error = null;
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _color,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.outlineVariant),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: M3ETextField(
                controller: _hexController,
                label: l10n.colorPickerHex,
                errorText: _error,
                leading: const Icon(Icons.tag_rounded),
                onChanged: _onHexChanged,
                autofocus: false,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _slider(
          context,
          label: l10n.colorPickerHue,
          valueLabel: '${_hsv.hue.round()}°',
          value: _hsv.hue,
          max: 360,
          divisions: 360,
          onChanged: (value) => _setHsv(_hsv.withHue(value)),
        ),
        _slider(
          context,
          label: l10n.colorPickerSaturation,
          valueLabel: '${(_hsv.saturation * 100).round()}%',
          value: _hsv.saturation * 100,
          max: 100,
          divisions: 100,
          onChanged: (value) => _setHsv(_hsv.withSaturation(value / 100)),
        ),
        _slider(
          context,
          label: l10n.colorPickerBrightness,
          valueLabel: '${(_hsv.value * 100).round()}%',
          value: _hsv.value * 100,
          max: 100,
          divisions: 100,
          onChanged: (value) => _setHsv(_hsv.withValue(value / 100)),
        ),
        if (widget.withAlpha)
          _slider(
            context,
            label: l10n.colorPickerOpacity,
            valueLabel: '${(_alpha * 100).round()}%',
            value: _alpha * 100,
            max: 100,
            divisions: 100,
            onChanged: (value) => _setHsv(_hsv, alpha: value / 100),
          ),
      ],
    );
  }

  Widget _slider(
    BuildContext context, {
    required String label,
    required String valueLabel,
    required double value,
    required double max,
    int? divisions,
    required ValueChanged<double> onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text(
                valueLabel,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          M3ESlider(
            value: value.clamp(0, max),
            min: 0,
            max: max,
            divisions: divisions,
            size: M3ESliderSize.xs,
            trackThickness: 6,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
