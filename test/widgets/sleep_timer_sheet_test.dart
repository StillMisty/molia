import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/sleep_timer_sheet.dart';

import '../support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PlaybackProvider playback;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    playback = buildTestPlaybackProvider(backend: FakePlaybackBackend());
    await playback.preferencesReady;
  });

  tearDown(() => playback.dispose());

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext host;
    await tester.pumpWidget(
      ChangeNotifierProvider<PlaybackProvider>.value(
        value: playback,
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
              host = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return host;
  }

  Future<void> openSheet(WidgetTester tester, BuildContext host) async {
    unawaited(showSleepTimerSheet(host));
    await tester.pumpAndSettle();
  }

  testWidgets('标题栏勾选保留，正文按定时方式分组', (tester) async {
    final host = await pumpHost(tester);
    await openSheet(tester, host);

    expect(find.byKey(const Key('sleepTimerExitAppCheckbox')), findsOneWidget);
    expect(find.byKey(const Key('sleepTimerStatusCard')), findsOneWidget);
    expect(find.text('定时方式'), findsOneWidget);
    expect(find.byKey(const Key('sleepTimerCustomItem')), findsOneWidget);
    expect(find.byKey(const Key('sleepTimerAfterTrackItem')), findsOneWidget);
    expect(find.byKey(const Key('sleepTimerCancelButton')), findsNothing);

    final before = playback.sleepTimer.exitApp.value;
    await tester.tap(find.byKey(const Key('sleepTimerExitAppCheckbox')));
    await tester.pump();
    expect(playback.sleepTimer.exitApp.value, isNot(before));

    Navigator.of(host).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('倒计时状态显示剩余时间与关闭按钮，窄屏不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    playback.sleepTimer.startCountdown(const Duration(minutes: 30));
    final host = await pumpHost(tester);
    await openSheet(tester, host);

    expect(find.text('剩余 30:00'), findsOneWidget);
    expect(find.byKey(const Key('sleepTimerCancelButton')), findsOneWidget);
    expect(tester.takeException(), isNull);

    Navigator.of(host).pop();
    await tester.pumpAndSettle();
  });
}
