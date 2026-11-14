import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/scrobble.dart';
import 'package:molia/domain/ports/scrobble_sink.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/listening_sync_page.dart';
import 'package:molia/services/scrobble/scrobble_outbox.dart';
import 'package:molia/services/scrobble/scrobble_preferences.dart';
import 'package:molia/services/scrobble/scrobble_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/settings_test_support.dart';

class _FakeSink implements ScrobbleSink, ScrobbleCredentialSink {
  _FakeSink(this.target);

  @override
  final ScrobbleTarget target;
  ScrobbleCredentialCheck check = const ScrobbleCredentialCheck.valid(
    'listener',
  );

  @override
  Future<ScrobbleCredentialCheck> validateCredential(String credential) async =>
      check;

  @override
  Future<ScrobbleDelivery> sendNowPlaying(ScrobbleListen listen) async =>
      const ScrobbleDelivery.success();

  @override
  Future<ScrobbleDelivery> sendScrobble(ScrobbleListen listen) async =>
      const ScrobbleDelivery.success();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScrobbleService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    service = ScrobbleService(
      preferences: ScrobblePreferences(
        settings: testSettingsRegistry(),
        prefs: prefs,
      ),
      outbox: ScrobbleOutbox(prefs: prefs),
      listenBrainzSink: _FakeSink(ScrobbleTarget.listenBrainz),
      autoDeliver: false,
    );
    await service.init();
  });

  tearDown(() => service.dispose());

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ScrobbleService>.value(
        value: service,
        child: M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData.light()),
          theme: ThemeData.light(),
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: const ListeningSyncPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('默认关闭，先看隐私说明才能连接', (tester) async {
    await pumpPage(tester);

    expect(find.byKey(const Key('listeningSyncMasterSwitch')), findsOneWidget);
    expect(find.textContaining('不会发送本地文件路径'), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);

    await tester.tap(find.text('连接').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('开启 ListenBrainz 的听歌同步'), findsOneWidget);
    expect(find.text('同意并开启'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.consentFor(ScrobbleTarget.listenBrainz), isFalse);
    expect(find.text('输入访问密码'), findsNothing);
  });

  testWidgets('同意后粘贴口令，状态显示账号', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('连接').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('同意并开启'));
    await tester.pumpAndSettle();

    expect(service.consentFor(ScrobbleTarget.listenBrainz), isTrue);
    expect(find.text('输入访问密码'), findsOneWidget);
    await tester.enterText(find.byType(M3ETextField), 'token-value');
    await tester.tap(find.widgetWithText(M3EButton, '连接').last);
    await tester.pumpAndSettle();

    expect(
      service.statusOf(ScrobbleTarget.listenBrainz),
      ScrobbleTargetStatus.connected,
    );
    expect(find.textContaining('已连接：listener'), findsOneWidget);
  });

  testWidgets('断开确认清空凭证与队列', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('连接').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('同意并开启'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(M3ETextField), 'token-value');
    await tester.tap(find.widgetWithText(M3EButton, '连接').last);
    await tester.pumpAndSettle();

    expect(find.text('断开连接'), findsOneWidget);
    await tester.tap(find.text('断开连接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('断开 ListenBrainz'), findsOneWidget);
    await tester.tap(find.widgetWithText(M3EButton, '断开连接').last);
    await tester.pumpAndSettle();

    expect(
      service.statusOf(ScrobbleTarget.listenBrainz),
      ScrobbleTargetStatus.disconnected,
    );
    expect(service.credentialFor(ScrobbleTarget.listenBrainz), isEmpty);
    expect(find.text('未连接'), findsOneWidget);
  });
}
