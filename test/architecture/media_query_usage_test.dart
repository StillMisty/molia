import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// MediaQuery 订阅守卫：只订阅用到的分面。
///
/// `MediaQuery.of(context)` 会让整棵子树在键盘 inset、尺寸、亮度、文字缩放等
/// 任一变化时重建；列表卡片 / 封面不需要这些，只取 DPR、padding 或 size 即可。
/// 这不是风格问题：键盘弹出 / 旋转时整页重建会直接掉帧（2026-11 的
/// 10k 曲库帧体检里已出现过一批残留）。
const Set<String> _wholeQueryAllowlist = {
  // 需要整份 MediaQueryData 拷贝，再把 disableAnimations 等字段一起改写。
  'lib/app/shell/themed_app.dart',
};

void main() {
  test('lib/ 内只用 MediaQuery 分面访问器，禁止整树订阅', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList();

    final pattern = RegExp(r'MediaQuery\.of\s*\(');
    final offending = <String>[];
    final stillMatching = <String>{};
    for (final file in files) {
      final path = file.path.replaceAll(r'\', '/');
      if (!pattern.hasMatch(file.readAsStringSync())) continue;
      stillMatching.add(path);
      if (!_wholeQueryAllowlist.contains(path)) offending.add(path);
    }

    expect(
      offending,
      isEmpty,
      reason:
          'MediaQuery.of() 会订阅整份 MediaQueryData；改用 '
          'devicePixelRatioOf / paddingOf / sizeOf / textScalerOf 等分面访问器，'
          '确需整份拷贝请评审后登记白名单：\n${offending.join('\n')}',
    );

    final stale = _wholeQueryAllowlist.difference(stillMatching);
    expect(
      stale,
      isEmpty,
      reason: 'MediaQuery 白名单条目已不再使用，请删除：\n${stale.join('\n')}',
    );
  });
}
