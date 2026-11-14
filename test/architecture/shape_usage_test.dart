import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 形状口径守卫（docs/architecture.md §6「M3E 设计语言」）。
///
/// M3E 的圆角是一套有限档位（xs 4 / sm 8 / md 12 / lg 16 / xl 28 / full），
/// 写死数字会让「同一语义」在不同页面漂移：封面曾经 10 / 12 / 14 混用、
/// 卡片在 8 与 10 之间来回；改一次全局形状也就无法只改一处。
///
/// 规则：
/// - S1 禁止 `BorderRadius.circular(<数字>)` 与 `Radius.circular(<数字>)`；
///   统一用 `M3EShapes.radiusSmall/Medium/Large/...`；胶囊（原 999）用
///   `const BorderRadius.all(Radius.circular(M3EShapes.full))`（包内没有
///   `radiusFull` 常量，只有 `full` 这个 double 与 `stadium`）。
/// - 由尺寸推导的圆角（`height / 2`、`size / 2`、`radius` 变量、条件表达式）
///   不是字面量，不在拦截范围——那本来就是「按几何取圆」的正确写法。
///
/// 白名单只放没有 `BuildContext`、按固定设计稿出图的海报导出管线（与
/// `m3e_typography_test` 对 `lyrics_poster_service` 的例外同一理由）。
const Set<String> _shapeLiteralAllowlist = {
  'lib/services/annual_poster_service.dart', // 海报导出固定设计稿（无 context）
};

/// 字面量圆角：`BorderRadius.circular(12)` / `Radius.circular(999)`。
///
/// 只认紧跟数字的写法：`Radius.circular(M3EShapes.full)`、
/// `Radius.circular(size / 2)`、`Radius.circular(isFirst ? a : b)` 都不命中。
final RegExp _literalRadiusPattern = RegExp(
  r'(?:BorderRadius|Radius)\.circular\(\s*\d',
);

void main() {
  final files = _libFiles();

  test('扫描到 lib/** 的 Dart 文件', () {
    expect(files, isNotEmpty);
    expect(files, contains('lib/main.dart'));
  });

  test('S1 圆角只用 M3EShapes token 或几何推导，不写死数字', () {
    final violations = <String>[];
    for (final path in files) {
      if (_shapeLiteralAllowlist.contains(path)) continue;
      final source = _strippedSource(path);
      for (final match in _literalRadiusPattern.allMatches(source)) {
        violations.add(
          '${match.group(0)} @ $path:${_lineOf(source, match.start)}',
        );
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          '这些位置还在写死圆角（改成 M3EShapes 的档位）：'
          '\n  ${violations.join('\n  ')}\n'
          '  档位见 package:material_3_expressive 的 M3EShapes；'
          '胶囊用 BorderRadius.all(Radius.circular(M3EShapes.full))。',
    );
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

/// 去掉注释再匹配：文档注释里会举「原来是 `Radius.circular(12)`」这类例子。
String _strippedSource(String path) {
  final file = File(path);
  if (!file.existsSync()) return '';
  final withoutBlocks = file.readAsStringSync().replaceAll(
    RegExp(r'/\*[\s\S]*?\*/'),
    '',
  );
  return withoutBlocks
      .split('\n')
      .map((line) {
        final index = line.indexOf('//');
        return index < 0 ? line : line.substring(0, index);
      })
      .join('\n');
}

int _lineOf(String source, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < source.length; i++) {
    if (source.codeUnitAt(i) == 0x0A) line++;
  }
  return line;
}
