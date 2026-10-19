import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_key.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/domain/models/device_sync.dart';

/// 「一个键一个家」：登记键的名字字面量只准出现在 `settings_keys.dart`。
///
/// 键名只在 `settings_keys.dart` 定义；组件与同步适配器一律引用登记键，
/// 这条扫描强制它只有一个落脚点（见 ADR-0003 决策 6）。
///
/// 只扫 `'名字'` 形式的字符串字面量：注释里用反引号提及键名是允许的。
void main() {
  test('快捷键四键已登记且跟人走（同步类别 settings）', () {
    const shortcutKeys = <SettingsKey<Object?>>[
      kShortcutsEnabled,
      kGlobalShortcutsEnabled,
      kShortcutBindings,
      kGlobalShortcutBindings,
    ];

    for (final key in shortcutKeys) {
      expect(
        kAllSettingsKeys,
        contains(key),
        reason: '${key.name} 必须在登记键总表里，否则永远不会同步',
      );
      expect(
        key.category,
        SyncCategory.settings,
        reason: '${key.name} 是跟人走的快捷键配置',
      );
    }
  });

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
