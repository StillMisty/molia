import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/theme/app_semantic_colors.dart';
import 'package:molia/theme/scheme_builder.dart';

/// WCAG 对比度：正文 / 次要文字 / 图标前景在明暗两套方案下都达到 AA。
///
/// 只检查现有 token 配对，不引入任何字面颜色；新增表面若换色，这里会先报。
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  const seeds = [Color(0xFF2196F3), Color(0xFF7C4DFF), Color(0xFF00897B)];

  for (final brightness in Brightness.values) {
    for (final seed in seeds) {
      final scheme = buildColorScheme(seed, brightness);
      final semantic = AppSemanticColors.fromScheme(scheme);
      final pairs = <String, (Color, Color)>{
        'onSurface/surface': (scheme.onSurface, scheme.surface),
        'onSurfaceVariant/surface': (scheme.onSurfaceVariant, scheme.surface),
        'onPrimary/primary': (scheme.onPrimary, scheme.primary),
        'onPrimaryContainer/primaryContainer': (
          scheme.onPrimaryContainer,
          scheme.primaryContainer,
        ),
        'onSecondaryContainer/secondaryContainer': (
          scheme.onSecondaryContainer,
          scheme.secondaryContainer,
        ),
        'onSurface/surfaceContainerHigh': (
          scheme.onSurface,
          scheme.surfaceContainerHigh,
        ),
        'onSuccess/success': (semantic.onSuccess, semantic.success),
        'onSuccessContainer/successContainer': (
          semantic.onSuccessContainer,
          semantic.successContainer,
        ),
        'onWarning/warning': (semantic.onWarning, semantic.warning),
        'onWarningContainer/warningContainer': (
          semantic.onWarningContainer,
          semantic.warningContainer,
        ),
      };
      test('${brightness.name} / ${seed.toARGB32().toRadixString(16)} 对比度', () {
        pairs.forEach((name, pair) {
          final ratio = contrastRatio(pair.$1, pair.$2);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason: '$name = ${ratio.toStringAsFixed(2)}:1，低于 AA 4.5:1',
          );
        });
      });
    }
  }
}
