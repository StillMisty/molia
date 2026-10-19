/// 设置注册表的「唯一实例」扫描：整表常量 `kAllSettingsKeys` 只准出现在
/// 组合根接线圈与设置层自身。
///
/// 同一份 prefs 上的第二份注册表不会接同步写入钩子（`onWrite` 是组合根在
/// 同步栈建好后接的），也不会进同步/备份范围。模块面一律经 `SettingsAccess` /
/// `SettingsScope` 注入；本扫描让漏注入 / 私自新建变成可见违规。
///
/// 以 `kAllSettingsKeys` 为锚点（而不是 `SettingsRegistry(` 的调用形状）：
/// 别名 / 嵌套括号都绕不开——只要整表常量在允许目录外被引用即违规；注释里的
/// 提及不算。
///
/// 允许位置：
/// - `lib/app/bootstrap/**`（组合根第一站，注册表的唯一构造点）；
/// - `lib/data/settings/**`（设置层自身的测试 / 契约代码）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 扫描锚点：整表登记键的常量名。
const String _keyTable = 'kAllSettingsKeys';

const List<String> _allowedPrefixes = [
  'lib/app/bootstrap/',
  'lib/data/settings/',
];

void main() {
  test('$_keyTable 只准在组合根与设置层引用', () {
    final files = _libFiles();
    expect(files, contains('lib/main.dart'), reason: '确认扫描到了 lib/**');

    final violations = <String>[];
    for (final path in files) {
      if (_allowedPrefixes.any(path.startsWith)) continue;
      final lines = _codeLines(path);
      for (var index = 0; index < lines.length; index++) {
        if (lines[index].contains(_keyTable)) {
          violations.add('$path:${index + 1} ${lines[index].trim()}');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: '整表注册表只由组合根（lib/app/bootstrap/**）构造；模块请依赖注入的 '
          'SettingsAccess / SettingsScope，不要引用 $_keyTable：\n'
          '${violations.join('\n')}',
    );
  });

  test('扫描锚点有效：允许目录内仍能扫到 $_keyTable', () {
    final seen = [
      for (final path in _libFiles())
        if (_allowedPrefixes.any(path.startsWith))
          if (_codeLines(path).any((line) => line.contains(_keyTable))) path,
    ];
    expect(
      seen,
      isNotEmpty,
      reason: '规则锚点失效（或整表常量改名 / 挪走）：先更新本扫描再提交',
    );
  });
}

List<String> _libFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .map((file) => file.path)
    .where((path) => path.endsWith('.dart'))
    .toList();

/// 每行去掉行注释（保留行号，便于定位）：注释里提及锚点不算违规。
List<String> _codeLines(String path) =>
    File(path).readAsStringSync().split('\n').map((line) {
      final index = line.indexOf('//');
      return index < 0 ? line : line.substring(0, index);
    }).toList();
