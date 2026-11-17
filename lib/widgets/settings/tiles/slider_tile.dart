import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../card_list_surface.dart';
import 'settings_tiles_support.dart';

/// 滑杆行：图标 + 标题/当前值 + 独占整行的滑杆（数值有区间）。
class SettingsSliderRow extends StatelessWidget {
  const SettingsSliderRow({
    super.key,
    required this.icon,
    required this.title,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
    this.divisions,
  });

  final IconData icon;
  final String title;

  /// 行尾当前值展示（如 `+50 ms` / `80%`）。
  final String valueLabel;

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  /// 拖动结束回调（松手 / 键盘调整完成）：用于把防抖中的连续值立即落盘。
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      semanticLabel: '$title, $valueLabel',
      onPressed: null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SettingsTileLead(icon: icon, title: title),
              ),
              const SizedBox(width: 8),
              Text(
                valueLabel,
                style: m3e.typeScale.bodyMedium.copyWith(
                  color: m3e.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          M3ESlider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            size: M3ESliderSize.xs,
            trackThickness: 6,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ],
      ),
    );
  }
}
