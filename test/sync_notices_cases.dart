import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/sync_notices.dart';
import 'package:molia/services/notification_service.dart';

import 'support/notification_recorder.dart';

/// 同步面底栏提示出口：统一走 `NotificationService`（内部 = M3ESnackbar），
/// 文案在 MaterialApp 之下解析（应用壳在 MaterialApp 之上，只能借宿主 context）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordingNotificationService notifications;

  setUp(() {
    notifications = RecordingNotificationService();
  });

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      Provider<NotificationService>.value(
        value: notifications,
        child: M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData.light()),
          theme: ThemeData.light(),
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Builder(
            builder: (context) {
              hostContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return hostContext;
  }

  testWidgets('已连通提示：用对端自报名，缺名时用短设备 id 兜底', (tester) async {
    final context = await pumpHost(tester);

    showSyncPeerConnectedNotice(
      context,
      const SyncPeerState(deviceId: 'devB', name: '书房'),
    );
    expect(notifications.last, '已与「书房」连通');

    showSyncPeerConnectedNotice(
      context,
      const SyncPeerState(deviceId: 'abcdef123456', name: ''),
    );
    expect(notifications.last, '已与「123456」连通', reason: '短设备 id 兜底');
  });
}
