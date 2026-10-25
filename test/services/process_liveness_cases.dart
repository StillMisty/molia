import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/window/process_liveness.dart';

/// 陈旧单实例锁的快速判定：pid 已退出时必须返回 false，否则启动会退回到
/// 2s loopback 连接超时。只覆盖本机 Linux / Windows 分支。
void main() {
  test(
    '当前进程存活；不存在的 pid 判为已退出',
    () {
      expect(isProcessAlive(pid), isTrue);
      expect(isProcessAlive(1 << 30), isFalse);
    },
    skip: !Platform.isLinux && !Platform.isWindows,
  );
}
