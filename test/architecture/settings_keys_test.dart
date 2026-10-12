import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_keys.dart';

/// 「一个键一个家」：登记键的名字字面量只准出现在 `settings_keys.dart`。
///
/// 动机（见 ADR-0003 §6 的 2026-10-12 修订）：同一个键曾经住在模块常量 /
/// 同步表 / 手写 reload 派发三处，漏一处不报错。现在键名是唯一事实，
/// 这条扫描强制它只有一个落脚点（组件与同步适配器一律引用登记键）。
///
/// 只扫 `'名字'` 形式的字符串字面量：注释里用反引号提及键名是允许的。
void main() {
  test('登记键名在 lib/ 中只出现在 settings_keys.dart', () {
    final files = _libFiles();
    expect(files, contains('lib/main.dart'), reason: '确认扫描到了 lib/**');

    final violations = <String>[];
    for (final key in kAllSettingsKeys) {
      final literal = "'${key.name}'";
      for (final path in files) {
        if (path == 'lib/data/settings/settings_keys.dart') continue;
        if (File(path).readAsStringSync().contains(literal)) {
          violations.add('$path 出现 $literal');
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '登记键名只能在 lib/data/settings/settings_keys.dart 声明：\n'
          '${violations.join('\n')}',
    );
  });

  test('登记键名唯一', () {
    final names = kAllSettingsKeys.map((key) => key.name).toSet();
    expect(names.length, kAllSettingsKeys.length);
  });
}

List<String> _libFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .map((file) => file.path)
    .where((path) => path.endsWith('.dart'))
    .toList();
