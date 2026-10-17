import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/transport/local_network_permission.dart';

/// 局域网权限通道：Dart 状态机与 Android 原生返回值之间的契约。
///
/// 原生实现见 `android/app/src/main/kotlin/top/stillmisty/molia/sync/
/// LocalNetworkPermissionChannelHandler.kt`；这里用 mock 通道锁定字符串协议，
/// 避免两端改名后静默退化成「永久拒绝」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('top.stillmisty.molia/local_network');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  void answer(Map<String, String> responses) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openAppSettings') return true;
      return responses[call.method];
    });
  }

  test('通道状态映射（含 limited / restricted 的等价语义）', () async {
    final cases = <(String, LocalNetworkPermissionStatus)>[
      ('granted', LocalNetworkPermissionStatus.granted),
      ('limited', LocalNetworkPermissionStatus.granted),
      ('provisional', LocalNetworkPermissionStatus.granted),
      ('denied', LocalNetworkPermissionStatus.denied),
      ('permanentlyDenied', LocalNetworkPermissionStatus.permanentlyDenied),
      ('restricted', LocalNetworkPermissionStatus.permanentlyDenied),
    ];
    for (final (wire, expected) in cases) {
      answer({'permissionStatus': wire, 'requestPermission': wire});
      final permission = LocalNetworkPermission.production();
      expect(
        await permission.refresh(),
        expected == LocalNetworkPermissionStatus.granted,
        reason: wire,
      );
      expect(permission.status, expected, reason: wire);
    }
  });

  test('ensure 经通道申请，授权后 granted', () async {
    answer({'permissionStatus': 'denied', 'requestPermission': 'granted'});
    final permission = LocalNetworkPermission.production();

    expect(await permission.ensure(), isTrue);
    expect(permission.status, LocalNetworkPermissionStatus.granted);
  });

  test('永久拒绝：ensure 不再申请，跳系统设置走通道', () async {
    var requested = 0;
    var opened = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'permissionStatus':
          return 'permanentlyDenied';
        case 'requestPermission':
          requested++;
          return 'denied';
        case 'openAppSettings':
          opened++;
          return true;
      }
      return null;
    });
    final permission = LocalNetworkPermission.production();

    expect(await permission.refresh(), isFalse);
    expect(permission.permanentlyDenied, isTrue);
    expect(await permission.ensure(retry: true), isFalse);
    expect(requested, 0);

    await permission.openSystemSettings();
    expect(opened, 1);
  });

  test('非 Android 平台不触达通道（Windows 不再有定位插件）', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return 'granted';
    });
    final permission = LocalNetworkPermission.production();

    expect(await permission.ensure(), isTrue);
    expect(await permission.refresh(), isTrue);
    expect(calls, 0);
  });
}
