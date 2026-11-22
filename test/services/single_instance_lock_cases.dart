/// 单实例纯逻辑：metadata 解析、锁冲突错误码分类、旧版升级守卫。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/window/single_instance_lock.dart';

void main() {
  group('SingleInstanceLock.parse', () {
    test('解析 pid / port', () {
      expect(SingleInstanceLock.parse('{"pid": 123, "port": 4567}'), (
        pid: 123,
        port: 4567,
      ));
    });

    test('port = 0 表示主实例存活但监听不可用', () {
      expect(SingleInstanceLock.parse('{"pid": 123, "port": 0}'), (
        pid: 123,
        port: 0,
      ));
    });

    test('空内容 / 半写 / 类型错误都返回 null', () {
      expect(SingleInstanceLock.parse(''), isNull);
      expect(SingleInstanceLock.parse('{"pid":'), isNull);
      expect(SingleInstanceLock.parse('{"pid": "1", "port": 2}'), isNull);
      expect(SingleInstanceLock.parse('{"pid": 1, "port": -1}'), isNull);
      expect(SingleInstanceLock.parse('{"pid": 1, "port": 65536}'), isNull);
      expect(SingleInstanceLock.parse('{"pid": 0, "port": 1}'), isNull);
    });
  });

  group('SingleInstanceLock.isLockConflict', () {
    test('Windows 只认 sharing / lock violation', () {
      expect(SingleInstanceLock.isLockConflict(32, onWindows: true), isTrue);
      expect(SingleInstanceLock.isLockConflict(33, onWindows: true), isTrue);
      expect(SingleInstanceLock.isLockConflict(5, onWindows: true), isFalse);
      expect(SingleInstanceLock.isLockConflict(null, onWindows: true), isFalse);
    });

    test('POSIX 认 EAGAIN / EACCES / macOS EAGAIN', () {
      expect(SingleInstanceLock.isLockConflict(11, onWindows: false), isTrue);
      expect(SingleInstanceLock.isLockConflict(13, onWindows: false), isTrue);
      expect(SingleInstanceLock.isLockConflict(35, onWindows: false), isTrue);
      // ENOLCK / EOPNOTSUPP：文件系统不支持锁，不能当成已有实例。
      expect(SingleInstanceLock.isLockConflict(37, onWindows: false), isFalse);
      expect(SingleInstanceLock.isLockConflict(95, onWindows: false), isFalse);
    });
  });

  group('SingleInstanceLock.decideUpgradeGuard', () {
    test('没有旧锁 / 读不出 / pid 已退出都继续', () {
      expect(
        SingleInstanceLock.decideUpgradeGuard(
          lockExists: false,
          readable: false,
          alive: false,
          connected: false,
        ),
        LegacyUpgradeAction.proceed,
      );
      expect(
        SingleInstanceLock.decideUpgradeGuard(
          lockExists: true,
          readable: false,
          alive: true,
          connected: false,
        ),
        LegacyUpgradeAction.proceed,
      );
      expect(
        SingleInstanceLock.decideUpgradeGuard(
          lockExists: true,
          readable: true,
          alive: false,
          connected: false,
        ),
        LegacyUpgradeAction.proceed,
      );
    });

    test('旧 pid 存活时连不上也按 secondary 退出', () {
      expect(
        SingleInstanceLock.decideUpgradeGuard(
          lockExists: true,
          readable: true,
          alive: true,
          connected: true,
        ),
        LegacyUpgradeAction.secondary,
      );
      expect(
        SingleInstanceLock.decideUpgradeGuard(
          lockExists: true,
          readable: true,
          alive: true,
          connected: false,
        ),
        LegacyUpgradeAction.secondaryUnresponsive,
      );
    });
  });
}
