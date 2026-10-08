import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/services/notification_service.dart';

/// M3E-P3-C 回归：NotificationService 内部改走 `M3ESnackbar.show` 后，
/// 仍能通过 home 宿主 context（ScaffoldMessenger 的 context 在 Overlay
/// 之上不可用）把提示展示出来，并保持「同时只显示一条」语义。
void main() {
  testWidgets('NotificationService 展示 M3ESnackbar 且新提示替换旧提示', (tester) async {
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    final appRootKey = GlobalKey(debugLabel: 'appRoot');
    final service = NotificationService(
      messengerKey,
      hostContextKey: appRootKey,
    );

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
}
