import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 排版口径守卫（docs/architecture.md §6「M3E 设计语言」）。
///
/// 为什么统一到 M3E typeScale：
/// - 应用里同时存在两套字号表——`ThemeData.textTheme`（Material 基线）与
///   `M3EThemeData.typeScale`。混用时同一个角色会拿到两套值；
///   `M3EThemeData.fromMaterial` 只把 baseline 映射进来，emphasized 变体
///   （品牌名 / 播放页标题等主动强调位）在 `textTheme` 里根本不存在。
/// - `buildM3EThemeData` 会把用户选的「应用字体」同步到 baseline 与
///   emphasized 两套字阶；直接从 `textTheme` 取值会绕过这次同步，用户换
///   字体后同一页出现两种字体。
/// - 取值统一走 `lib/theme/m3e_context.dart` 的 `context.typeScale` /
///   `context.emphasizedTypeScale`，字号 / 行高 / 字重只在一处演进。
///
/// 为什么海报服务例外：`lyrics_poster_service.dart` 跑在导出管线里，没有
/// `BuildContext`、也拿不到页面主题；那里的排版是设计稿规格（固定字号 /
/// 字重），要保证任何主题下导出的图一致，不属于 UI 主题口径。
///
/// 规则：
/// - T1 非白名单文件不得出现小写 `textTheme`（不误伤 `TextTheme`）；
/// - T2 非白名单文件不得出现 `FontWeight.w600 / w800 / w900`（off-token
///   字重；`FontWeight.bold` = w700，允许）。
const Set<String> _textThemeAllowlist = {
  'lib/theme/app_theme.dart', // 构建 ThemeData，并把字体同步进两套字阶
  'lib/theme/m3e_context.dart', // 迁移说明里引用 textTheme（文档）
};

const Set<String> _fontWeightAllowlist = {
  'lib/services/lyrics_poster_service.dart', // 海报导出固定排版（无 context）
};

void main() {
  final files = _libFiles();

  test('扫描到 lib/** 的 Dart 文件', () {
    expect(files, isNotEmpty);
    expect(files, contains('lib/main.dart'));
    expect(files, containsAll(_textThemeAllowlist));
  });

  test('T1 UI 排版统一走 M3E typeScale，不直接读 ThemeData.textTheme', () {
    final violations = <String>[];
    for (final path in files) {
      if (_textThemeAllowlist.contains(path)) continue;
      final source = _strippedSource(path);
      for (final match in _textThemePattern.allMatches(source)) {
        violations.add('$path:${_lineOf(source, match.start)}');
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '这些位置还在用 Material textTheme（改成 context.typeScale）：'
          '\n  ${violations.join('\n  ')}\n'
          '  取值入口见 lib/theme/m3e_context.dart；强调位用 emphasizedTypeScale。',
    );
  });

  test('T2 字重只用 M3E token，不写 off-token 的 w600/w800/w900', () {
    final violations = <String>[];
    for (final path in files) {
      if (_fontWeightAllowlist.contains(path)) continue;
      final source = _strippedSource(path);
      for (final match in _fontWeightPattern.allMatches(source)) {
        violations.add(
          '${match.group(0)} @ $path:${_lineOf(source, match.start)}',
        );
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '这些位置用了 off-token 字重（强调位改用 emphasized 字阶或 w700）：'
          '\n  ${violations.join('\n  ')}\n'
          '  M3E 字重档位是 w400 / w500 / w700。',
    );
  });

  test('T3 白名单没有陈旧条目（文件与标识符都还在）', () {
    for (final path in {..._textThemeAllowlist, ..._fontWeightAllowlist}) {
      expect(files, contains(path), reason: '白名单里的 $path 不存在了，更新本文件');
    }
    // 注释里的说明也算「标识符还在」：m3e_context.dart 正是用注释解释口径。
    for (final path in _textThemeAllowlist) {
      expect(
        _textThemePattern.hasMatch(_rawSource(path)),
        isTrue,
        reason: '$path 里已经找不到 textTheme，可以从白名单移除',
      );
    }
    for (final path in _fontWeightAllowlist) {
      expect(
        _fontWeightPattern.hasMatch(_rawSource(path)),
        isTrue,
        reason: '$path 里已经找不到 w600/w800/w900，可以从白名单移除',
      );
    }
  });
}

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

/// 小写 `textTheme`；大小写敏感，`TextTheme` 类型名不会命中。
final RegExp _textThemePattern = RegExp(r'\btextTheme\b');

/// `FontWeight.w600` 等 off-token 字重；`\b` 防止命中 `w6000` 之类拼写。
final RegExp _fontWeightPattern = RegExp(r'\bFontWeight\.w(?:600|800|900)\b');

/// 去掉行注释后再匹配：注释里提到旧属性名不算违规。
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

String _rawSource(String path) =>
    File(path).existsSync() ? File(path).readAsStringSync() : '';

int _lineOf(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;
