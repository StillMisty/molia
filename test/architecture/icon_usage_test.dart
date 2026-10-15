import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 图标契约守卫（docs/architecture.md §6「M3E 设计语言」）：
/// 图标统一圆角风格 `Icons.*_rounded`，防止回退到基础实心 / `_outlined` /
/// 平台自适应（`Icons.adaptive.*`）。
///
/// 唯一例外是导航「未选中」半对（选中/未选中成对图标按 M3 惯例：
/// 未选中空心、选中实心）：资料库没有圆角空心字形，退用 `_outlined`；
/// 音符不使用图标字形，由 Molia 标志组件（`lib/widgets/molia_mark.dart`）承载。
const Set<String> _outlinedPairAllowlist = {
  'library_music_outlined',
};

/// I2 例外：`IconSwap` 本身（配方所在处）、曲目行「缩略图 ⇄ 多选勾选」
/// （不是按钮图标槽位切换，语义是封面被勾选态替换）、歌词页扩展行
/// 「展开 ⇄ 收起」（不是按钮图标槽位切换，语义是翻译 / 罗马音随行淡出收起）。
const Set<String> _animatedSwitcherAllowlist = {
  'lib/widgets/icon_swap.dart',
  'lib/widgets/track_row.dart',
  'lib/widgets/lyrics.dart',
};

void main() {
  final files = _libFiles();

  test('扫描到 lib/** 的 Dart 文件', () {
    expect(files, isNotEmpty);
    expect(files, contains('lib/main.dart'));
  });

  test('I1 所有 Icons.* 均为圆角风格（导航未选中半对除外）', () {
    final violations = <String>[];
    for (final path in files) {
      for (final match in _iconsPattern.allMatches(_strippedSource(path))) {
        final name = match.group(1)!;
        if (name.endsWith('_rounded')) continue;
        if (_outlinedPairAllowlist.contains(name)) continue;
        violations.add('[Icons.$name] $path');
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '图标统一 `Icons.*_rounded`（例外见测试文件注释）：\n'
          '${violations.join('\n')}',
    );
  });

  test('I2 同一按钮的状态图标切换统一走 IconSwap（不裸写 AnimatedSwitcher）', () {
    final violations = <String>[];
    for (final path in files) {
      if (_animatedSwitcherAllowlist.contains(path)) continue;
      if (_strippedSource(path).contains('AnimatedSwitcher(')) {
        violations.add(path);
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '图标切换统一走 `lib/widgets/icon_swap.dart::IconSwap` '
          '（docs/architecture.md §6）：\n${violations.join('\n')}',
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

/// `Icons.<name>` 引用；`Icons.adaptive.*` 会被捕获为 `adaptive` 并判违规。
/// `M3EIcons.*` 因词边界不匹配，不会误报。
final RegExp _iconsPattern = RegExp(r'\bIcons\.([A-Za-z0-9_]+)');

/// 去掉行注释后再匹配：避免注释里提到非圆角图标名造成误报。
String _strippedSource(String path) {
  final file = File(path);
  if (!file.existsSync()) return '';
  return file.readAsStringSync().split('\n').map((line) {
    final index = line.indexOf('//');
    return index < 0 ? line : line.substring(0, index);
  }).join('\n');
}
