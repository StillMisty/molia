/// 设置注册表的「唯一实例」扫描：`SettingsRegistry(keys: kAllSettingsKeys)`
/// 只准出现在组合根接线圈与设置层自身。
///
/// 模块此前可以用同一个 fallback 静默铸造私有注册表：同一份 prefs 上的第二
/// 份注册表不会接同步写入钩子（`onWrite` 是组合根在同步栈建好后接的），
/// 也不会进同步/备份范围。模块面一律经 `SettingsAccess` / `SettingsScope`
/// 注入；本扫描让漏注入 / 私自新建变成可见违规。
///
/// 允许位置：
/// - `lib/app/bootstrap/**`（组合根第一站，注册表的唯一构造点）；
/// - `lib/data/settings/**`（设置层自身的测试 / 契约代码）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 匹配 `SettingsRegistry(keys: kAllSettingsKeys)`（允许换行与空格）。
final RegExp _privateRegistry = RegExp(
  r'SettingsRegistry\s*\([^)]*kAllSettingsKeys',
  dotAll: true,
);

const List<String> _allowedPrefixes = [
  'lib/app/bootstrap/',
  'lib/data/settings/',
];

void main() {
  test('kAllSettingsKeys 注册表只准在组合根与设置层构造', () {
    final files = _libFiles();
    expect(files, contains('lib/main.dart'), reason: '确认扫描到了 lib/**');

    final violations = <String>[];
    for (final path in files) {
      if (_allowedPrefixes.any(path.startsWith)) continue;
      final match = _privateRegistry.firstMatch(
        File(path).readAsStringSync(),
      );
      if (match != null) {
        violations.add('$path 私自构造整表注册表：${_snippet(match.group(0)!)}');
      }
    }

    expect(
      violations,
      isEmpty,
      reason: '模块应依赖注入的 SettingsAccess / SettingsScope：\n'
          '${violations.join('\n')}',
    );
  });
}

List<String> _libFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .map((file) => file.path)
    .where((path) => path.endsWith('.dart'))
    .toList();

String _snippet(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();
