import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/services/notification_permission.dart';
import 'package:molia/services/notification_service.dart';

/// 通知能力测试面：`NotificationService` 经 `M3ESnackbar.show` 展示的语义
/// （提示走 home 宿主 context，ScaffoldMessenger 的 context 在 Overlay 之上
/// 不可用；同时只显示一条，新提示替换旧提示），以及通知权限门面契约
/// （状态解析 / 每会话至多请求一次 / 设置深链）。真实弹窗与设置页在原生侧
/// （MainActivity 的 `top.stillmisty.molia/notifications` 通道），这里只验证
/// Dart 契约。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('NotificationService 展示 M3ESnackbar 且新提示替换旧提示', (tester) async {
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    final appRootKey = GlobalKey(debugLabel: 'appRoot');
    final service = NotificationService(hostContextKey: appRootKey);

    await tester.pumpWidget(
      M3EMaterialApp(
        data: M3EThemeData.light(),
        scaffoldMessengerKey: messengerKey,
        home: Builder(
          key: appRootKey,
          builder: (context) => Scaffold(
            body: Center(
              child: M3EButton(
                onPressed: () => service.showSnackBar('信息提示'),
                child: const Text('show'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('信息提示'), findsOneWidget);
    expect(M3ESnackbar.defaultController.isShowing, isTrue);

    // 第二条提示替换第一条（removeCurrentSnackBar 语义）。
    await tester.tap(find.text('show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('信息提示'), findsOneWidget);
  });

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
