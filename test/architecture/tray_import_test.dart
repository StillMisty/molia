import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 托盘 / 显示器原生依赖的隔离（与 `window_chrome` 的约束同源，见
/// docs/pitfalls.md #30）：`tray_manager` / `nativeapi` 的 Dart 代码 import
/// `dart:io` 与 `dart:ffi`，全仓只允许在桌面 IO 实现里出现。
///
/// UI / 组合根一律经 `lib/services/window/app_tray.dart` 入口（直接导出 io 实现）。
void main() {
  const allowedPaths = <String>{
    'lib/services/window/app_tray_io.dart',
    'lib/services/window/display_areas_io.dart',
  };
  const packagePrefixes = <String>[
    'package:tray_manager/',
    'package:nativeapi/',
    'package:nativeapi_flutter/',
  ];

  test('托盘 / 显示器原生包只出现在桌面 IO 实现', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => file.path)
        .where((path) => path.endsWith('.dart'))
        .toList();
    expect(files, contains('lib/main.dart'), reason: '确认扫描到了 lib/**');

    final violations = <String>[];
    for (final path in files) {
      if (allowedPaths.contains(path)) continue;
      final source = File(path).readAsStringSync();
      for (final prefix in packagePrefixes) {
        if (source.contains(prefix)) violations.add('$path 引用了 $prefix');
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '托盘 / 显示器实现只能走桌面 IO 入口：\n${violations.join('\n')}',
    );

    // 反向断言：防止入口改名 / 扫描失灵后本测试静默通过。
    expect(
      File('lib/services/window/app_tray_io.dart').readAsStringSync(),
      contains('package:tray_manager/'),
    );
    expect(
      File('lib/services/window/display_areas_io.dart').readAsStringSync(),
      contains('package:nativeapi/'),
    );
  });

  test('入口直接导出 io 实现（无 stub 分支）', () {
    final entry = File('lib/services/window/app_tray.dart').readAsStringSync();
    expect(entry, contains("export 'app_tray_io.dart';"));
    expect(entry, isNot(contains('app_tray_stub.dart')));
    expect(
      File('lib/services/window/app_tray_stub.dart').existsSync(),
      isFalse,
      reason: '入口直接导出 io 实现，不应再有 stub 文件',
    );
  });
}
