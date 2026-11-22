import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/battery_probe.dart';

/// 电池探针契约：Map 解析、MissingPlugin / 异常按未知降级（ADR-0038 阶段 2）。
///
/// 测试宿主是 Linux，走通道分支；Android 的 JNI 分支由集成基准 / 冒烟覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('top.stillmisty.molia/battery');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('解析电量 / 充电 / 系统省电模式', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'snapshot');
          return <String, Object?>{
            'level': 87,
            'charging': true,
            'powerSave': true,
          };
        });

    final snapshot = await BatteryProbe().read();
    expect(snapshot.level, 87);
    expect(snapshot.charging, isTrue);
    expect(snapshot.powerSave, isTrue);
  });

  test('字段缺失 / 类型不符按未知处理', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return <String, Object?>{'level': 'bad'};
        });

    final snapshot = await BatteryProbe().read();
    expect(snapshot.level, -1);
    expect(snapshot.charging, isFalse);
    expect(snapshot.powerSave, isFalse);
  });

  test('MissingPluginException → unknown', () async {
    // 不注册 handler：invokeMethod 直接抛 MissingPluginException。
    final snapshot = await BatteryProbe().read();
    expect(snapshot.level, BatterySnapshot.unknown.level);
    expect(snapshot.charging, isFalse);
    expect(snapshot.powerSave, isFalse);
  });

  test('通道异常 → unknown', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'BOOM');
        });

    final snapshot = await BatteryProbe().read();
    expect(snapshot.level, -1);
    expect(snapshot.charging, isFalse);
    expect(snapshot.powerSave, isFalse);
  });

  test('Android 以外的平台不触碰 JNI（本机 Linux 分支）', () async {
    if (Platform.isAndroid) return;
    expect(Platform.isAndroid, isFalse);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return <String, Object?>{'level': 65};
        });
    expect((await BatteryProbe().read()).level, 65);
  });
}
