import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 裸 Material 组件守卫（docs/architecture.md §6「组件」）。
///
/// UI 必须走 `M3E*` 组件（`package:material_3_expressive`），裸 Material
/// 组件会绕过 M3E 的形状 / 状态层 / 动效 / 无障碍约定——最典型的是
/// `InkWell` 没有键盘激活语义、`SnackBar` 走的是另一套观感。迁移已完成，
/// 剩余未替换的调用点都是长期例外，按「文件 → 标识符」逐条登记在本文件；
/// 禁止在调用点就地开洞，否则口径会一处一处地回潮。
///
/// 白名单里只有长期例外（没有待迁移条目）：
/// - `ReorderableListView`：M3E 1.2.0 未导出 reorder host，
///   收藏页 / 设置页 / 通用分段列表只能继续用框架实现；
/// - `SelectableText` / `Tooltip` / 透明或容器 `Material`：包内没有等价件
///   （逐条理由见下表）。
///
/// 扫描前去掉注释与字符串，只认精确标识符（`M3EDivider`、`M3ETooltip`
/// 这类带前缀的写法不会误报；`DividerThemeData` 这类更长标识符同理）。
/// 每个例外都在下面的表里写清理由；替换一项就删一条。
const Map<String, Set<String>> _rawComponentAllowlist = {
  // 壳层底栏容器：容器色（surfaceContainer）+ 布局约束，不是可点表面；
  // M3E 没有等价的底栏容器，保留。
  'lib/app/desktop/now_playing_bar.dart': {'Material'},
  // 收藏页可重排列表：M3E 1.2.0 未导出 reorder host，长期例外。
  'lib/pages/favorites.dart': {'ReorderableListView'},
  // 同步口令 / 设备 id 需要「可选中复制」；M3E 没有 SelectableText 等价件。
  'lib/pages/sync_dialogs.dart': {'SelectableText'},
  // M3E 底部弹层 / 侧边弹层的宿主不提供 Material 祖先，透明 Material 只
  // 补 ink 绘制层（弹窗本体已全部走 M3E 组件）。
  'lib/utils/responsive.dart': {
    'Material',
  },
  // AI 提示词预览需要可选中复制。
  'lib/widgets/ai_dj_prompt_dialog.dart': {'SelectableText'},
  // M3E 1.2.0 未导出 reorder host，长期例外（收藏页 / 设置页 / 通用列表）。
  'lib/widgets/collection_track_list.dart': {'ReorderableListView'},
  // 自建全屏搜索遮罩（docs/pitfalls.md #57）：路由与透明 ink 祖先都是
  // 有意保留，不换 M3ESearchAnchor。
  'lib/widgets/global_search_overlay.dart': {'Material', 'showGeneralDialog'},
  // 歌词滚动区：透明 Material 只补 ink 绘制层（滚动容器本身不是 M3E 组件）。
  'lib/widgets/lyrics.dart': {'Material'},
  // 设置页可重排分段列表：M3E 1.2.0 未导出 reorder host，长期例外。
  'lib/widgets/settings/settings_reorderable_rows.dart': {
    'ReorderableListView',
  },
  // 热力图格子的值提示：需要 400ms wait，M3ETooltip 没有 wait API。
  'lib/widgets/statistics/listening_heatmap.dart': {'Tooltip'},
  // 音量浮层表面（surfaceContainerHigh + elevation）：M3E 没有等价的
  // popover 容器，保留。
  'lib/widgets/volume_control.dart': {'Material'},
};

/// 需要拦截的裸 Material 组件标识符。
const Set<String> _rawComponents = {
  'SnackBar',
  'ScaffoldMessenger',
  'Divider',
  'Dialog',
  'showDialog',
  'showGeneralDialog',
  'AppBar',
  'ReorderableListView',
  'InkWell',
  'Material',
  'Tooltip',
  'SelectableText',
};

/// 去掉注释与字符串，保留换行以便报行号；字符串里的插值代码一并丢弃
/// （目标标识符不会只在插值表达式里出现，简单规则足够）。
String _stripCommentsAndStrings(String source) {
  final out = StringBuffer();
  var index = 0;
  var blockDepth = 0;
  var lineComment = false;
  String? quote;
  var raw = false;
  var triple = false;

  while (index < source.length) {
    final char = source[index];
    final next = index + 1 < source.length ? source[index + 1] : '';

    if (lineComment) {
      if (char == '\n') {
        lineComment = false;
        out.write('\n');
      } else {
        out.write(' ');
      }
      index++;
      continue;
    }
    if (blockDepth > 0) {
      if (char == '/' && next == '*') {
        blockDepth++;
        out.write('  ');
        index += 2;
        continue;
      }
      if (char == '*' && next == '/') {
        blockDepth--;
        out.write('  ');
        index += 2;
        continue;
      }
      if (char == '\n') {
        out.write('\n');
      } else {
        out.write(' ');
      }
      index++;
      continue;
    }
    if (quote != null) {
      if (!raw && char == r'\') {
        // 转义：跳过下一个字符，换行要保留。
        out.write(' ');
        index++;
        if (index < source.length) {
          out.write(source[index] == '\n' ? '\n' : ' ');
          index++;
        }
        continue;
      }
      if (triple) {
        if (char == quote &&
            next == quote &&
            index + 2 < source.length &&
            source[index + 2] == quote) {
          quote = null;
          triple = false;
          out.write('   ');
          index += 3;
          continue;
        }
      } else if (char == quote) {
        quote = null;
        out.write(' ');
        index++;
        continue;
      }
      out.write(char == '\n' ? '\n' : ' ');
      index++;
      continue;
    }

    if (char == '/' && next == '/') {
      lineComment = true;
      out.write('  ');
      index += 2;
      continue;
    }
    if (char == '/' && next == '*') {
      blockDepth = 1;
      out.write('  ');
      index += 2;
      continue;
    }

    final isRawPrefix = (char == 'r' || char == 'R') &&
        (next == '"' || next == "'") &&
        (index == 0 || !RegExp(r'[A-Za-z0-9_]').hasMatch(source[index - 1]));
    if (isRawPrefix) {
      raw = true;
      out.write(' ');
      index++;
      continue;
    }

    if (char == '"' || char == "'") {
      quote = char;
      raw = false;
      triple = source.startsWith(char * 3, index);
      out.write(triple ? '   ' : ' ');
      index += triple ? 3 : 1;
      continue;
    }

    out.write(char);
    index++;
  }

  return out.toString();
}

/// 在 [source] 中查找 [identifier] 的出现行号。
List<int> _occurrences(String source, String identifier) {
  final pattern = identifier == 'Material'
      // 只认裸 Material 构造：`MaterialPageRoute` 等更长标识符已被边界挡住。
      ? RegExp(r'(?<![A-Za-z0-9_.])Material(?![A-Za-z0-9_])(?=\s*\()')
      : RegExp(
          '(?<![A-Za-z0-9_.])${RegExp.escape(identifier)}(?![A-Za-z0-9_])',
        );
  return [
    for (final match in pattern.allMatches(source))
      '\n'.allMatches(source.substring(0, match.start)).length + 1,
  ];
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

  test('裸 Material 组件只允许登记在案的文件 / 标识符', () {
    final stripped = <String, String>{
      for (final path in files)
        path: _stripCommentsAndStrings(
          File(path).readAsStringSync(),
        ),
    };

    final offenders = <String>[];
    for (final entry in stripped.entries) {
      final allowed = _rawComponentAllowlist[entry.key] ?? const <String>{};
      for (final identifier in _rawComponents) {
        if (allowed.contains(identifier)) continue;
        for (final line in _occurrences(entry.value, identifier)) {
          offenders.add('${entry.key}:$line $identifier');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些地方还在用裸 Material 组件（换 M3E 组件，或先在 '
          '_rawComponentAllowlist 登记并写清理由）：\n  '
          '${offenders.join('\n  ')}',
    );
  });

  test('白名单没有陈旧条目（文件被删 / 标识符已不再使用）', () {
    final stale = <String>[];
    for (final entry in _rawComponentAllowlist.entries) {
      final path = entry.key;
      if (!files.contains(path)) {
        stale.add('$path（文件不存在）');
        continue;
      }
      final source = _stripCommentsAndStrings(File(path).readAsStringSync());
      for (final identifier in entry.value) {
        if (_occurrences(source, identifier).isEmpty) {
          stale.add('$path → $identifier（已不再出现）');
        }
      }
    }

    expect(
      stale,
      isEmpty,
      reason: '白名单条目已经过期，删掉它们，避免白名单掩盖新违规：\n  '
          '${stale.join('\n  ')}',
    );
  });
}
