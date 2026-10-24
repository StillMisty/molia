import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 提示口径守卫（docs/architecture.md §6「按钮选型」）。
///
/// 纯图标按钮的语义载体是 `semanticLabel`，不是 `tooltip`：图标能自解释时，
/// 悬浮 / 长按 / 键盘焦点弹出的提示气泡是噪音（桌面鼠标密集扫过尤其明显）。
/// 提示只留给「图标表达不了的文本」，且例外必须在本文件登记——别在调用点
/// 就地开洞，否则口径会一处一处地回潮。
const Set<String> _rawTooltipAllowlist = {
  // 格子是数据值，不是动作；且 400ms wait 是热力图刚需，M3ETooltip 没有
  // wait API。
  'lib/widgets/statistics/listening_heatmap.dart',
};

/// 免给 `semanticLabel` 的 M3EIconButton：图标本身带名（由调用方给的
/// `Icon.semanticLabel`），可聚焦节点仍能念出动作名，见
/// `collectionSwipeActions`（`lib/widgets/collection_track_list.dart`）。
const Set<String> _iconLabelInIconAllowlist = {
  'lib/widgets/swipe_reveal_row.dart',
};

/// 扫描 [source] 中 `name(` 调用的参数文本与行号（括号配对，跳过字符串 / 注释）。
List<({String body, int line})> _callArguments(String source, String name) {
  final calls = <({String body, int line})>[];
  for (final match in RegExp('$name\\s*\\(').allMatches(source)) {
    var index = match.end - 1;
    var depth = 0;
    String? quote;
    var lineComment = false;
    var blockComment = false;
    while (index < source.length) {
      final char = source[index];
      if (lineComment) {
        if (char == '\n') lineComment = false;
      } else if (blockComment) {
        if (char == '*' && source.startsWith('/', index + 1)) {
          blockComment = false;
          index++;
        }
      } else if (quote != null) {
        if (char == '\\') {
          index++;
        } else if (char == quote) {
          quote = null;
        }
      } else if (char == '/' && source.startsWith('/', index + 1)) {
        lineComment = true;
        index++;
      } else if (char == '/' && source.startsWith('*', index + 1)) {
        blockComment = true;
        index++;
      } else if (char == '"' || char == "'") {
        quote = char;
      } else if (char == '(') {
        depth++;
      } else if (char == ')') {
        depth--;
        if (depth == 0) break;
      }
      index++;
    }
    calls.add((
      body: source.substring(match.end, index),
      line: '\n'.allMatches(source.substring(0, match.start)).length + 1,
    ));
  }
  return calls;
}

void main() {
  final files = [
    for (final entity in Directory('lib').listSync(recursive: true))
      if (entity is File && entity.path.endsWith('.dart')) entity.path,
  ];

  test('扫描到 lib/** 的 Dart 文件', () {
    expect(files, isNotEmpty);
    expect(files, contains('lib/main.dart'));
  });

  test('T1 M3EIconButton 不得传 tooltip（语义走 semanticLabel）', () {
    final offenders = <String>[];
    var scanned = 0;
    for (final path in files) {
      final source = File(path).readAsStringSync();
      for (final call in _callArguments(source, 'M3EIconButton')) {
        scanned++;
        if (RegExp(r'\btooltip\s*:').hasMatch(call.body)) {
          offenders.add('$path:${call.line}');
        }
      }
    }
    // 扫描器失灵（括号配对断掉、调用语形变了）时不能静默通过。
    expect(scanned, greaterThan(20), reason: '没扫到几个 M3EIconButton 调用，先检查扫描器');
    expect(
      offenders,
      isEmpty,
      reason: '这些 M3EIconButton 还在用 tooltip（改成 semanticLabel:）：'
          '\n  ${offenders.join('\n  ')}\n'
          '  提示只留给图标表达不了的文本，见本文件顶部说明。',
    );
  });

  test('T2 M3EIconButton 必须给 semanticLabel（无障碍名）', () {
    final offenders = <String>[];
    var scanned = 0;
    for (final path in files) {
      final source = File(path).readAsStringSync();
      for (final call in _callArguments(source, 'M3EIconButton')) {
        scanned++;
        if (RegExp(r'\bsemanticLabel\s*:').hasMatch(call.body)) continue;
        if (_iconLabelInIconAllowlist.contains(path)) continue;
        offenders.add('$path:${call.line}');
      }
    }
    expect(scanned, greaterThan(20), reason: '没扫到几个 M3EIconButton 调用，先检查扫描器');
    expect(
      offenders,
      isEmpty,
      reason: '这些 M3EIconButton 没有无障碍名（加 semanticLabel:）：'
          '\n  ${offenders.join('\n  ')}\n'
          '  图标上的名只能救急，按钮自己的节点才是读屏落点。',
    );
  });

  test('T3 裸 Tooltip( 只允许登记在案的白名单文件', () {
    // 白名单文件改名 / 删除时，规则要跟着显形，不能静默失效。
    for (final path in _rawTooltipAllowlist) {
      expect(files, contains(path),
          reason: '白名单里的 $path 不存在了，更新 _rawTooltipAllowlist');
    }
    final pattern = RegExp(r'(?<![\w.])Tooltip\s*\(');
    final offenders = <String>[];
    var allowed = 0;
    for (final path in files) {
      if (_rawTooltipAllowlist.contains(path)) {
        allowed += pattern.allMatches(File(path).readAsStringSync()).length;
        continue;
      }
      final source = File(path).readAsStringSync();
      for (final match in pattern.allMatches(source)) {
        final line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        offenders.add('$path:$line');
      }
    }
    expect(allowed, greaterThan(0), reason: '白名单文件里已经找不到 Tooltip(，规则可以收紧');
    expect(
      offenders,
      isEmpty,
      reason: '图标按钮的提示会随鼠标扫过弹出；要加新例外，'
          '先在 _rawTooltipAllowlist 登记并写清理由：\n  ${offenders.join('\n  ')}',
    );
  });
}
