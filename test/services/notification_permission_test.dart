import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/notification_permission.dart';

/// 通知权限门面：状态解析、每会话至多请求一次、设置深链。
///
/// 真实弹窗/设置页在原生侧（MainActivity 的
/// `top.stillmisty.molia/notifications` 通道），这里只验证 Dart 契约。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('top.stillmisty.molia/notifications');
  late List<String> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'permissionStatus':
          return 'denied';
        case 'requestPermission':
          return 'permanentlyDenied';
        case 'openNotificationSettings':
          return true;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('状态解析：granted / denied / permanentlyDenied / 未知', () async {
    for (final (raw, expected) in <(String, NotificationPermissionStatus)>[
      ('granted', NotificationPermissionStatus.granted),
      ('denied', NotificationPermissionStatus.denied),
      ('permanentlyDenied', NotificationPermissionStatus.permanentlyDenied),
      ('weird', NotificationPermissionStatus.unsupported),
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => raw);
      expect(await NotificationPermission.status(), expected, reason: raw);
    }
  });

  test('ensureRequested：每个会话至多弹一次（后续只查状态）', () async {
    final first = await NotificationPermission.ensureRequested();
    expect(first, NotificationPermissionStatus.permanentlyDenied);
    expect(calls, ['requestPermission']);

    final second = await NotificationPermission.ensureRequested();
    expect(second, NotificationPermissionStatus.denied);
    expect(calls, ['requestPermission', 'permissionStatus']);
  });

  test('openSettings：调用原生设置深链入口', () async {
    await NotificationPermission.openSettings();
    expect(calls, ['openNotificationSettings']);
  });
}
