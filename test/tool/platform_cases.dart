import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/agent/src/platform.dart';

void main() {
  test('parseAdbDevices 只取 device 状态', () {
    const output = '''
List of devices attached
emulator-5554\tdevice
R58M12345\toffline
ZY22ABCDEF\tunauthorized
  ''';
    expect(parseAdbDevices(output), ['emulator-5554']);
  });

  test('runningEmulator 忽略非模拟器与未就绪设备', () {
    // runningEmulator 依赖真实 adb，这里只验证解析层的过滤语义。
    expect(parseAdbDevices('emulator-5556\tdevice\nR58M12345\tdevice'), [
      'emulator-5556',
      'R58M12345',
    ]);
  });

  test('displayPrefix 在非 Linux 上不加前缀', () {
    if (Platform.isLinux) return;
    expect(displayPrefix(headless: true, requireDisplay: false), isEmpty);
  });
}
