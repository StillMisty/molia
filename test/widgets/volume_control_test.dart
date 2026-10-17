import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/volume_control.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

/// 音量入口（底栏与播放页传输排共用）：面板定位、读数、静音与键盘操作。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playback;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
  });

  tearDown(() => playback.dispose());

  Future<void> pumpControl(
    WidgetTester tester, {
    Size size = const Size(400, 400),
    Alignment alignment = Alignment.center,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<PlaybackProvider>.value(
        value: playback,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(
            body: Align(alignment: alignment, child: const VolumeControl()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder volumeButton() => find.byType(M3EIconButton);

  testWidgets('读数：默认满音量显示 100%，静音只换图标不丢音量', (tester) async {
    await pumpControl(tester);
    expect(playback.volume, 1.0, reason: '前提：测试 provider 初始音量 1.0');

    await tester.tap(volumeButton());
    await tester.pumpAndSettle();
    final panel = find.byType(M3ESlider);
    expect(panel, findsOneWidget);
    expect(find.text('100%'), findsOneWidget);

    // 面板内静音键：图标态即反馈，音量值保留（取消静音回到原音量）。
    await tester.tap(find.byType(M3EIconButton).last);
    await tester.pumpAndSettle();
    expect(playback.muted, isTrue);
    expect(playback.volume, 1.0);
    expect(find.text('100%'), findsOneWidget);
    expect(find.byIcon(Icons.volume_off_rounded), findsWidgets);

    // Esc 关闭（占用登记，不依赖焦点位置）。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(M3ESlider), findsNothing);
  });

  testWidgets('键盘：面板一出现滑杆就持有焦点，方向键即可调音量', (tester) async {
    await pumpControl(tester);
    await tester.tap(volumeButton());
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(playback.volume, lessThan(1.0));
    expect(backend.volumes, isNotEmpty, reason: '音量已下发后端');

    final double lowered = playback.volume;
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(playback.volume, greaterThan(lowered));

    // 音量落盘防抖计时器跑完，避免 pending timer 报错。
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('窄宿主：面板收窄并贴边，不越出宿主可绘制区', (tester) async {
    await pumpControl(
      tester,
      size: const Size(200, 300),
      alignment: Alignment.centerLeft,
    );

    await tester.tap(volumeButton());
    await tester.pumpAndSettle();

    final slider = find.byType(M3ESlider);
    expect(slider, findsOneWidget);
    // 面板整体落在窗口内（锚点在左缘时向右夹回，而不是推出屏幕）。
    final panelRect = tester.getRect(slider);
    expect(panelRect.left, greaterThanOrEqualTo(0));
    expect(panelRect.right, lessThanOrEqualTo(200));
    expect(tester.takeException(), isNull);
  });
}
