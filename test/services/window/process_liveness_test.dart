import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/window/foreground_activation.dart';
import 'package:molia/services/window/process_liveness.dart';

/// 进程存活 / 前台激活的顶层函数：只在 Linux 上验证 POSIX 分支；
/// Windows 分支靠 CI 编译 + 冒烟（ADR-0038）。
void main() {
  test('当前进程存活', () {
    expect(isProcessAlive(pid), isTrue);
  });

  test('0 / 负数视为无效 pid', () {
    expect(isProcessAlive(0), isFalse);
    expect(isProcessAlive(-1), isFalse);
  });

  test('Linux 上极大 pid 不存在', () {
    // 超过 pid_max 的值走 ESRCH，必须判为已退出。
    expect(isProcessAlive(0x7fffffff), isFalse);
  }, skip: !Platform.isLinux);

  test('非 Windows 不允许设置前台窗口', () {
    expect(allowSetForegroundWindow(pid), isFalse);
  });
}
