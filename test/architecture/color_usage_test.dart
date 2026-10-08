import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 配色契约守卫（AGENTS.md「M3E 约定」/ docs/architecture.md §6）：
/// 颜色只能来自 ColorScheme 角色、AppSemanticColors 语义色或主题基建，
/// 防止重新长回「同语义不同颜色」的散装取色。
///
/// 规则：
/// - C1 禁止 `withAlpha(...)`：透明度统一 `withValues(alpha:)`；
/// - C2 禁止 `Colors.*` 字面量（`Colors.transparent` 除外）；
/// - C3 禁止 `Color(0x...)` 字面量（主题基建/种子色定义白名单除外）；
/// - C4 禁止在 `lib/theme/app_theme.dart` 之外构建 `ThemeData(`；
/// - C5 禁止 legacy 双源属性：`scaffoldBackgroundColor`、`dividerColor`、
///   `withOpacity`（统一走 colorScheme.surface / outlineVariant / withValues）。
///
/// 白名单只放「定义颜色本身」的基础设施，不接受业务页面豁免。
const Set<String> _colorLiteralAllowlist = {
  'lib/providers/theme_provider.dart', // 种子色预设 + 纯黑覆盖
  'lib/theme/app_semantic_colors.dart', // success/warning 种子
  'lib/theme/app_theme.dart', // Colors.transparent 系统栏 + ThemeData 构建
};

void main() {
  final files = _libFiles();

  test('扫描到 lib/** 的 Dart 文件', () {
    expect(files, isNotEmpty);
    expect(files, contains('lib/main.dart'));
  });

  test('C1/C5 透明度与 legacy 双源属性无违规', () {
    final violations = <String>[];
    for (final path in files) {
      final source = _strippedSource(path);
      for (final pattern in const ['withAlpha(', 'withOpacity(']) {
        if (source.contains(pattern)) {
          violations.add('[$pattern] $path');
        }
      }
      for (final property in const [
        'scaffoldBackgroundColor',
        'dividerColor',
      ]) {
        if (source.contains(property)) {
          violations.add('[$property] $path');
        }
      }
    }
    expect(violations, isEmpty, reason: '请统一到 colorScheme 角色：\n${violations.join('\n')}');
  });

  test('C2/C3 原始颜色字面量只允许出现在主题基建', () {
    final violations = <String>[];
    for (final path in files) {
      if (_colorLiteralAllowlist.contains(path)) continue;
      final source = _strippedSource(path);
      for (final match in _colorsPattern.allMatches(source)) {
        violations.add('[${match.group(0)}] $path');
      }
      if (_rawColorPattern.hasMatch(source)) {
        violations.add('[Color(0x...)] $path');
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '颜色必须来自 ColorScheme / AppSemanticColors：\n${violations.join('\n')}',
    );
  });

  test('C4 ThemeData 只在 app_theme.dart 构建', () {
    final violations = <String>[];
    for (final path in files) {
      if (path == 'lib/theme/app_theme.dart') continue;
      if (_themeDataPattern.hasMatch(_strippedSource(path))) {
        violations.add(path);
      }
    }
    expect(violations, isEmpty, reason: '主题唯一出口是 buildAppThemeData：\n${violations.join('\n')}');
  });
}

// ---------------------------------------------------------------------------
// 扫描实现
// ---------------------------------------------------------------------------

List<String> _libFiles() {
  final dir = Directory('lib');
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .map((file) => file.path.replaceAll('\\', '/'))
      .where((path) => path.endsWith('.dart'))
      .toList()
    ..sort();
}

/// `Colors.xxx` 字面量；`Colors.transparent` 是「无色」语义，全局放行。
/// `\b` 防止把 `AppSemanticColors.of` 误判为字面量。
final RegExp _colorsPattern =
    RegExp(r'\bColors\.(?!transparent\b)[A-Za-z]+');

/// `Color(0x...)` / `Color.fromARGB(...)` 等构造字面量。
final RegExp _rawColorPattern = RegExp(r'Color\(0x|Color\.fromARGB');

/// `ThemeData(` 构造；负向环视排除 `buildAppThemeData(` / `M3EThemeData(`。
final RegExp _themeDataPattern = RegExp(r'(?<![A-Za-z_])ThemeData\(');

/// 去掉行注释后再匹配：避免注释里提到旧属性名造成误报。
String _strippedSource(String path) {
  final file = File(path);
  if (!file.existsSync()) return '';
  return file
      .readAsStringSync()
      .split('\n')
      .map((line) {
        final index = line.indexOf('//');
        return index < 0 ? line : line.substring(0, index);
      })
      .join('\n');
}
