import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/theme/app_theme.dart';
import 'package:molia/widgets/cover_hero.dart';
import 'package:molia/widgets/m3e_page_route.dart';

/// 预测返回（Android 边缘返回）的回归：主题必须挂预测 builder，手势必须
/// 真的驱动路由动画；带 Hero / SnackBar 时也不能把 detector 打断。
///
/// 背景：跟手预览只由 `PredictiveBackPageTransitionsBuilder` 插入的 detector
/// 提供；若主题被依赖包默认值换成普通 builder，或 Hero 在
/// `NavigatorObserver.didStartUserGesture` 里抛异常，表现都是「慢拖完全不动、
/// 松手直接返回」。这些用例把两条链路都钉住。
void main() {
  test('页面过渡统一沿用依赖包默认 map，Android 仍为预测返回', () {
    final theme = buildAppThemeData(
      ColorScheme.fromSeed(seedColor: const Color(0xFF2196F3)),
    );

    final defaultBuilders = const PageTransitionsTheme().builders;
    expect(
      theme.pageTransitionsTheme.builders,
      defaultBuilders,
      reason: '主题不要手写一份平台子集，统一沿用依赖包默认 map',
    );

    final android = defaultBuilders[TargetPlatform.android];
    expect(android, isA<PredictiveBackPageTransitionsBuilder>());
    expect(android, isNot(isA<FadeForwardsPageTransitionsBuilder>()));
  });

  for (final withHeroAndSnackBar in <bool>[false, true]) {
    testWidgets(
      withHeroAndSnackBar
          ? 'Hero + SnackBar 下手势仍驱动根路由动画'
          : '手势驱动根路由动画，取消回弹、提交只退一级',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        final theme = buildAppThemeData(
          ColorScheme.fromSeed(seedColor: const Color(0xFF2196F3)),
        );
        final navigatorKey = GlobalKey<NavigatorState>();
        late ModalRoute<dynamic> pageRoute;

        Widget cover(String tag, double size) {
          final Widget box = SizedBox.square(
            dimension: size,
            child: const ColoredBox(color: Color(0xFF2196F3)),
          );
          return withHeroAndSnackBar ? CoverHero(tag: tag, child: box) : box;
        }

        await tester.pumpWidget(
          M3EMaterialApp(
            data: buildM3EThemeData(theme),
            theme: theme,
            darkTheme: theme,
            navigatorKey: navigatorKey,
            home: Scaffold(body: Center(child: cover('hero', 56))),
          ),
        );

        navigatorKey.currentState!.push(
          M3EPageRoute<void>(
            builder: (context) {
              pageRoute = ModalRoute.of(context)!;
              return Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [cover('hero', 200), const Text('second page')],
                  ),
                ),
              );
            },
          ),
        );
        await tester.pumpAndSettle();

        if (withHeroAndSnackBar) {
          final messenger = tester.state<ScaffoldMessengerState>(
            find.byType(ScaffoldMessenger).first,
          );
          messenger.showSnackBar(const SnackBar(content: Text('saved')));
          await tester.pump();
        }

        await _sendBackGesture(
          tester,
          const MethodCall('startBackGesture', <String, dynamic>{
            'touchOffset': <double>[5.0, 300.0],
            'progress': 0.0,
            'swipeEdge': 0,
          }),
        );

        expect(tester.takeException(), isNull);
        expect(navigatorKey.currentState!.userGestureInProgress, isTrue);

        await _sendBackGesture(
          tester,
          const MethodCall('updateBackGestureProgress', <String, dynamic>{
            'x': 100.0,
            'y': 300.0,
            'progress': 0.35,
            'swipeEdge': 0,
          }),
        );
        expect(pageRoute.animation!.value, closeTo(0.65, 0.001));

        await _sendBackGesture(tester, const MethodCall('cancelBackGesture'));
        await tester.pumpAndSettle();

        expect(pageRoute.animation!.value, 1.0);
        expect(find.text('second page'), findsOneWidget);
        expect(navigatorKey.currentState!.userGestureInProgress, isFalse);

        // 再走一次提交：只退一级，不能把 root 也带走。
        await _sendBackGesture(
          tester,
          const MethodCall('startBackGesture', <String, dynamic>{
            'touchOffset': <double>[5.0, 300.0],
            'progress': 0.0,
            'swipeEdge': 0,
          }),
        );
        await _sendBackGesture(
          tester,
          const MethodCall('updateBackGestureProgress', <String, dynamic>{
            'x': 300.0,
            'y': 300.0,
            'progress': 0.7,
            'swipeEdge': 0,
          }),
        );
        await _sendBackGesture(tester, const MethodCall('commitBackGesture'));
        await tester.pumpAndSettle();

        expect(find.text('second page'), findsNothing);
        expect(navigatorKey.currentState!.canPop(), isFalse);
      },
    );
  }
}

Future<void> _sendBackGesture(WidgetTester tester, MethodCall call) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(call),
    (_) {},
  );
  await tester.pump();
}
