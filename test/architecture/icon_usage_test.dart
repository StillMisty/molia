import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 图标契约守卫（AGENTS.md「M3E 约定」）：
/// 图标统一圆角风格 `Icons.*_rounded`，防止回退到基础实心 / `_outlined` /
/// 平台自适应（`Icons.adaptive.*`）。
///
/// 唯一例外是导航「未选中」半对（选中/未选中成对图标按 M3 惯例：
/// 未选中空心、选中实心）：资料库没有圆角空心字形，退用 `_outlined`；
/// 音符已改用 Molia 标志组件（`lib/widgets/molia_mark.dart`），不再用字形。
const Set<String> _outlinedPairAllowlist = {
  'library_music_outlined',
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
