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
    bool disableAnimations = false,
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
          builder: disableAnimations
              ? (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: true),
                  child: child!,
                )
              : null,
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

  testWidgets('减弱动效：面板直接开合，不排入场 / 退场帧', (tester) async {
    await pumpControl(tester, disableAnimations: true);

    // 零时长：一次 pump 就应完全打开（不是先把面板挂在透明 / 缩放中间态）。
    await tester.tap(volumeButton());
    await tester.pump();
    expect(find.byType(M3ESlider), findsOneWidget);

    await tester.tap(volumeButton().first);
    await tester.pump();
    expect(find.byType(M3ESlider), findsNothing);
  });

  testWidgets('关闭动画：落定后移除 overlay；途中重开不被旧关闭请求误关', (tester) async {
    await pumpControl(tester);

    await tester.tap(volumeButton());
    await tester.pumpAndSettle();
    expect(find.byType(M3ESlider), findsOneWidget);

    // 点外部开始退场：动画期间保留视觉（避免突兀消失），但已不再接收点击。
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.byType(M3ESlider), findsOneWidget, reason: '退场动画中面板仍在');

    // 途中重开：旧的 whenComplete 不能把新面板关掉。
    await tester.tap(volumeButton().first);
    await tester.pumpAndSettle();
    expect(find.byType(M3ESlider), findsOneWidget);

    // 再关闭：动画落定后 overlay 必须完全移除（不残留可命中的面板）。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(M3ESlider), findsNothing);
  });
}
