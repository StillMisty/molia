import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 托盘依赖的隔离（与 `window_chrome` 的约束同源，见 docs/pitfalls.md #30）：
/// `tray_manager` / `nativeapi` 的 Dart 代码 import `dart:io` 与 `dart:ffi`，
/// 被参与 Web 编译的代码引用会让 `flutter build web` 直接失败。
///
/// 因此全仓只有 `app_tray_io.dart`（条件导出的 io 分支）可以 import 它们；
/// UI / 组合根一律经 `lib/services/window/app_tray.dart` 入口。
void main() {
  const allowedPath = 'lib/services/window/app_tray_io.dart';
  const packagePrefixes = <String>[
    'package:tray_manager/',
    'package:nativeapi/',
    'package:nativeapi_flutter/',
  ];

  test('托盘包只出现在 $allowedPath', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => file.path)
        .where((path) => path.endsWith('.dart'))
        .toList();
    expect(files, contains('lib/main.dart'), reason: '确认扫描到了 lib/**');

    final violations = <String>[];
    for (final path in files) {
      if (path == allowedPath) continue;
      final source = File(path).readAsStringSync();
      for (final prefix in packagePrefixes) {
        if (source.contains(prefix)) violations.add('$path 引用了 $prefix');
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '托盘实现只能在 $allowedPath（其余代码走 app_tray.dart 条件导出）：\n'
          '${violations.join('\n')}',
    );

    // 反向断言：防止入口改名 / 扫描失灵后本测试静默通过。
    final impl = File(allowedPath).readAsStringSync();
    expect(impl, contains('package:tray_manager/'));
  });

  test('条件导出入口覆盖 stub 与 io 两个实现', () {
    final entry = File('lib/services/window/app_tray.dart').readAsStringSync();
    expect(entry, contains("'app_tray_stub.dart'"));
    expect(entry, contains("'app_tray_io.dart'"));
  });
}
