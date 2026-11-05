import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/sleep_timer.dart';
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

  void setScreenSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

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

  testWidgets('无顶栏勾选/关闭按钮，正文为滑杆和两个默认勾选', (tester) async {
    setScreenSize(tester, const Size(390, 844));
    final host = await pumpHost(tester);
    await openSheet(tester, host);

    expect(find.byIcon(Icons.close_rounded), findsNothing);
    expect(find.byKey(const Key('sleepTimerDurationSlider')), findsOneWidget);
    expect(find.byKey(const Key('sleepTimerStatusText')), findsOneWidget);
    expect(find.byKey(const Key('sleepTimerCustomItem')), findsNothing);
    expect(find.byKey(const Key('sleepTimerAfterTrackItem')), findsNothing);
    expect(find.text('定时方式'), findsNothing);

    final exit = find.byKey(const Key('sleepTimerExitAppCheckbox'));
    final wait = find.byKey(const Key('sleepTimerWaitForTrackCheckbox'));
    expect(exit, findsOneWidget);
    expect(wait, findsOneWidget);
    expect(tester.widget<M3ECheckbox>(exit).value, isTrue);
    expect(tester.widget<M3ECheckbox>(wait).value, isTrue);

    // 一左一右：同一水平线，退出应用在左、本曲播完在右。
    final exitCenter = tester.getCenter(exit);
    final waitCenter = tester.getCenter(wait);
    expect(exitCenter.dy, closeTo(waitCenter.dy, 0.5));
    expect(exitCenter.dx, lessThan(waitCenter.dx));

    await tester.tap(exit);
    await tester.pump();
    await tester.tap(wait);
    await tester.pump();
    expect(playback.sleepTimer.exitApp.value, isFalse);
    expect(playback.sleepTimer.waitForTrackEnd.value, isFalse);

    Navigator.of(host).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('滑杆松手开始倒计时，窄屏不溢出', (tester) async {
    setScreenSize(tester, const Size(320, 640));
    final host = await pumpHost(tester);
    await openSheet(tester, host);

    expect(find.text('30 分钟'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.drag(
      find.byKey(const Key('sleepTimerDurationSlider')),
      const Offset(120, 0),
    );
    await tester.pump();

    expect(playback.sleepTimer.value.mode, SleepTimerMode.countdown);
    expect(playback.sleepTimer.value.duration, isNotNull);
    expect(find.textContaining('剩余'), findsOneWidget);
    expect(find.byKey(const Key('sleepTimerCancelButton')), findsOneWidget);
    expect(tester.takeException(), isNull);

    Navigator.of(host).pop();
    await tester.pumpAndSettle();
  });
}
