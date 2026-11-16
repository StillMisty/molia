import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/m3e_context.dart';

/// 缓存策略数值的显示：整 GB 显示为 GB（1024 → 1 GB），其余 MB。
String cachePolicySizeLabel(AppLocalizations l10n, int value) {
  if (value <= 0) return l10n.cacheUnlimited;
  if (value % 1024 == 0) return l10n.cacheValueGb(value ~/ 1024);
  return l10n.cacheValueMb(value);
}

/// 缓存策略数值弹层：只接受 0 或 [min, max] 内的整数。
///
/// 0 沿用 [CacheService] 语义（不限制 / 永不过期）；确认后返回新值，
/// 取消返回 null。缓存页与高级设置共用同一套校验与预设，避免两处口径漂移。
Future<int?> showCachePolicyValueDialog(
  BuildContext context, {
  required String title,
  required int current,
  required int min,
  required int max,
  required String unitLabel,
  required String zeroLabel,
  required String Function(int value) labelOf,
  List<int>? presets,
  int? suggestedMb,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final initialText = '$current';
  final controller = TextEditingController(text: initialText)
    // 全选当前值：直接输入即替换，省去先删再填。
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: initialText.length,
    );
  final result = await M3EDialog.show<int>(
    context,
    dialog: StatefulBuilder(
      builder: (context, setState) {
        final parsed = int.tryParse(controller.text.trim());
        final valid =
            parsed != null && (parsed == 0 || (parsed >= min && parsed <= max));
        return M3EDialog(
          title: title,
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (suggestedMb != null) ...[
                  Text(
                    l10n.cacheAudioMaxSuggested(
                      cachePolicySizeLabel(l10n, suggestedMb),
                    ),
                    style: context.typeScale.bodySmall.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (presets != null) ...[
                  Wrap(
                    spacing: 8,
                    // 换行后行距不能为 0：chips 贴边会被看成叠在一起。
                    runSpacing: 8,
                    children: [
                      for (final preset in presets)
                        M3EChip(
                          type: M3EChipType.filter,
                          label: labelOf(preset),
                          selected: parsed == preset,
                          onPressed: () {
                            controller.text = '$preset';
                            controller.selection = TextSelection.collapsed(
                              offset: controller.text.length,
                            );
                            setState(() {});
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                M3ETextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  suffixText: unitLabel,
                  supportingText: l10n.cacheCustomHint(zeroLabel, min, max),
                  errorText: controller.text.isNotEmpty && !valid
                      ? l10n.cacheCustomRangeError(min, max)
                      : null,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: valid
                      ? (_) => Navigator.pop(context, parsed)
                      : null,
                ),
              ],
            ),
          ),
          actions: [
            M3EButton.text(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.cancel),
            ),
            M3EButton.filled(
              onPressed: valid ? () => Navigator.pop(context, parsed) : null,
              child: Text(l10n.saveChanges),
            ),
          ],
        );
      },
    ),
  );
  controller.dispose();
  return result;
}
