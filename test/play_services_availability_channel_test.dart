import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/play_services_availability.dart';

/// Play 服务可用性通道：Dart 门控与 Android 原生返回值之间的契约。
///
/// 原生实现见 `android/app/src/main/kotlin/top/stillmisty/molia/sync/
/// PlayServicesChannelHandler.kt`；这里用 mock 通道锁定方法名与布尔协议，
/// 并锁定「true 缓存 / false 不缓存 / Android 之外不触达通道」的语义。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('top.stillmisty.molia/play_services');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  var calls = 0;

  void answer(bool Function() value) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      expect(call.method, 'isAvailable', reason: '方法名是协议的一部分');
      return value();
    });
  }

  setUp(() {
    calls = 0;
    PlayServicesAvailability.resetCache();
    PlayServicesAvailability.debugOverride = null;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    PlayServicesAvailability.debugOverride = null;
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('Android：通道返回 true/false 原样映射', () async {
    answer(() => true);
    expect(await PlayServicesAvailability.isAvailable(), isTrue);

    PlayServicesAvailability.resetCache();
    answer(() => false);
    expect(await PlayServicesAvailability.isAvailable(), isFalse);
  });

  test('true 会话内缓存：第二次不再触达通道', () async {
    answer(() => true);
    expect(await PlayServicesAvailability.isAvailable(), isTrue);
    expect(await PlayServicesAvailability.isAvailable(), isTrue);
    expect(calls, 1, reason: 'GMS 一次运行里不会消失：true 缓存');
  });

  test('false 不缓存：用户装了 Play 服务后重探要能变 true', () async {
    var available = false;
    answer(() => available);
    expect(await PlayServicesAvailability.isAvailable(), isFalse);
    available = true;
    expect(await PlayServicesAvailability.isAvailable(), isTrue,
        reason: 'false 不缓存，重开弹层应能出现扫码入口');
    expect(calls, 2);
  });

  test('通道缺失 / 异常：按不可用处理（不抛给调用方）', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'UNAVAILABLE');
    });
    expect(await PlayServicesAvailability.isAvailable(), isFalse);
  });

  test('通道无响应：2s 超时按不可用处理', () {
    messenger.setMockMethodCallHandler(channel, (call) => Completer<bool>().future);
    final async = FakeAsync();
    var result = true;
    async.run((_) {
      unawaited(PlayServicesAvailability.isAvailable().then((value) => result = value));
      async.elapse(PlayServicesAvailability.probeTimeout);
      async.flushMicrotasks();
    });
    expect(result, isFalse);
  });

  test('iOS 恒可用且不触达通道；桌面恒不可用', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    answer(() => true);
    expect(await PlayServicesAvailability.isAvailable(), isTrue);
    expect(calls, 0, reason: 'iOS 走系统 Vision，不需要 GMS 探测');

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(await PlayServicesAvailability.isAvailable(), isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(await PlayServicesAvailability.isAvailable(), isFalse);
    expect(calls, 0);
  });

  test('debugOverride 覆盖一切（供 widget 测试注入）', () async {
    PlayServicesAvailability.debugOverride = () async => true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      throw StateError('debugOverride 生效时不应触达通道');
    });
    expect(await PlayServicesAvailability.isAvailable(), isTrue);
    expect(calls, 0);
  });
}
