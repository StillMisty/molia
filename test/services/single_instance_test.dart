import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/window/single_instance_lock.dart';

/// 单实例锁文件的纯逻辑：内容编解码、格式校验与探测结论。
///
/// IO（独占创建 / loopback 连接）不在本文件覆盖：`decide` 是「陈旧锁清理
/// 与保守放行」的全部决策点，边界必须钉死。
void main() {
  group('encode / parse', () {
    test('编解码往返：pid / port 原样还原', () {
      final raw = SingleInstanceLock.encode(pid: 1234, port: 45678);
      expect(SingleInstanceLock.parse(raw), (pid: 1234, port: 45678));
    });

    test('格式不符（半写 / 截断 / 非对象 / 字段缺失或类型错）返回 null', () {
      expect(SingleInstanceLock.parse(''), isNull);
      expect(SingleInstanceLock.parse('{"pid":1'), isNull);
      expect(SingleInstanceLock.parse('[]'), isNull);
      expect(SingleInstanceLock.parse('"text"'), isNull);
      expect(SingleInstanceLock.parse('{"pid": 1}'), isNull);
      expect(SingleInstanceLock.parse('{"port": 8080}'), isNull);
      expect(SingleInstanceLock.parse('{"pid": "1", "port": 8080}'), isNull);
      expect(SingleInstanceLock.parse('{"pid": 1, "port": "8080"}'), isNull);
    });

    test('越界值视为无效：pid / port 必须为正，port 在 1..65535', () {
      expect(SingleInstanceLock.parse('{"pid": 0, "port": 8080}'), isNull);
      expect(SingleInstanceLock.parse('{"pid": -1, "port": 8080}'), isNull);
      expect(SingleInstanceLock.parse('{"pid": 1, "port": 0}'), isNull);
      expect(SingleInstanceLock.parse('{"pid": 1, "port": 65536}'), isNull);
      expect(
        SingleInstanceLock.parse('{"pid": 1, "port": 65535}'),
        (pid: 1, port: 65535),
      );
    });
  });

  group('decide', () {
    test('连得上：无论第几次尝试都判为 secondary', () {
      for (var attempt = 1;
          attempt <= SingleInstanceLock.maxAcquireAttempts;
          attempt++) {
        expect(
          SingleInstanceLock.decide(connected: true, attempt: attempt),
          SingleInstanceAction.secondary,
        );
      }
    });

    test('连不上：未到上限重抢，达到上限保守按主实例', () {
      expect(
        SingleInstanceLock.decide(connected: false, attempt: 1),
        SingleInstanceAction.retryAcquire,
      );
      expect(
        SingleInstanceLock.decide(connected: false, attempt: 2),
        SingleInstanceAction.retryAcquire,
      );
      expect(
        SingleInstanceLock.decide(connected: false, attempt: 3),
        SingleInstanceAction.fallbackPrimary,
      );
    });
  });
}
