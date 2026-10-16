import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// M3E 按钮用法扫描：**`label` 不带 `icon` 会渲染成空按钮**。
///
/// `material_3_expressive` 1.1.7 的 `_buildButtonCore` 只在
/// `icon != null && label != null` 时才布局 label，否则回退到 `child`
/// （都没有就是 `SizedBox.shrink()`）。`M3EButton.filled(label: Text('保存'))`
/// 因此在界面上是一个**看不见内容的按钮**——同步设置页的确认按钮曾整片沦陷，
/// 用户只看到空白按钮，属于「功能其实在、但用户按不到」的静默故障。
///
/// 规则：普通动作按钮一律用 `child:`；只有「图标 + 文案」形态（会走 selection /
/// icon 布局）或选择态按钮才用 `label:`（此时必须同时有 `icon:`）。
void main() {
  test('M3EButton 的 label 必须与 icon 同用（否则退回 child）', () {
    final offenders = <String>[];
    final variants = RegExp(r'M3EButton\.(filled|tonal|elevated|outlined)\s*\(');
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();
      for (final match in variants.allMatches(src)) {
        var index = match.end - 1;
        var depth = 0;
        while (index < src.length) {
          final char = src[index];
          if (char == '(') {
            depth++;
          } else if (char == ')') {
            depth--;
            if (depth == 0) break;
          }
          index++;
        }
        final args = src.substring(match.end, index);
        final hasLabel = RegExp(r'\blabel\s*:').hasMatch(args);
        final hasIcon = RegExp(r'\bicon\s*:').hasMatch(args);
        if (hasLabel && !hasIcon) {
          final line = '\n'.allMatches(src.substring(0, match.start)).length + 1;
          offenders.add('${entity.path}:$line');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '这些 M3EButton 用 label 但没给 icon（会渲染成空按钮）：$offenders\n'
          '  → 普通动作按钮改成 child: Text(...)，或补上 icon:。',
    );
  });
}
