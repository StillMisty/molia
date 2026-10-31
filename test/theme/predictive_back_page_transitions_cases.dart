import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'package:molia/theme/app_theme.dart';
import 'package:molia/widgets/m3e_page_route.dart';

/// Android 预测返回契约：应用主题下 push 的页面必须被手势接管（跟手预览）、
/// 可取消回位、可提交出栈。
///
/// 手势事件走 `SystemChannels.backGesture`（与 engine 真机下发同一通道）。
/// 「有观察者接管」的判据是 `Navigator.userGestureInProgress`：只有接管手势的
/// 观察者（`PredictiveBackPageTransitionsBuilder` 内的 detector）会经
/// `TransitionRoute.handleStartBackGesture` 调进去；没人接管时框架退化成普通
/// 返回（能出栈、全程无预览），该标记保持 false。所以本文件既测「跟手」，
/// 也充当「别把 Android 页面过渡换成普通 builder」的回归护栏。
void main() {
  const seed = Color(0xFF2196F3);

  Map<String, dynamic> backArgs(double progress) => <String, dynamic>{
        'touchOffset': <double>[5, 600],
        'progress': progress,
        'swipeEdge': 0,
      };

  Future<void> sendBack(
    WidgetTester tester,
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    final data = const StandardMethodCodec()
        .encodeMethodCall(MethodCall(method, args));
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.backGesture.name,
      data,
      (ByteData? _) {},
    );
  }

  /// 挂载应用主题的最小 App（测试环境平台为 Android），并 push 一个可返回页。
  Future<NavigatorState> pumpPushedPage(WidgetTester tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppThemeData(ColorScheme.fromSeed(seedColor: seed)),
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Center(child: Text('home'))),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('page'))),
      ),
    );
    await tester.pumpAndSettle();
    return navigatorKey.currentState!;
  }

  testWidgets('手势接管：页面跟手位移，取消后回位', (tester) async {
    final navigator = await pumpPushedPage(tester);
    final rest = tester.getTopLeft(find.text('page'));

    await sendBack(tester, 'startBackGesture', backArgs(0));
    await tester.pump();
    expect(
      navigator.userGestureInProgress,
      isTrue,
      reason: 'start 必须被页面过渡接管，否则没有跟手预览',
    );

    // 从左边缘划到 60%：页面应随手指向右位移（缩放到 0.9 + 平移）。
    await sendBack(tester, 'updateBackGestureProgress', backArgs(0.6));
    await tester.pump();
    final dragged = tester.getTopLeft(find.text('page'));
    expect(dragged.dx, greaterThan(rest.dx + 5));

    await sendBack(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();
    expect(navigator.userGestureInProgress, isFalse);
    expect(find.text('page'), findsOneWidget);
    final settled = tester.getTopLeft(find.text('page'));
    expect(settled.dx, moreOrLessEquals(rest.dx, epsilon: 0.5));
    expect(settled.dy, moreOrLessEquals(rest.dy, epsilon: 0.5));
  });

  testWidgets('提交手势：页面出栈回到上一页', (tester) async {
    await pumpPushedPage(tester);

    await sendBack(tester, 'startBackGesture', backArgs(0));
    await sendBack(tester, 'updateBackGestureProgress', backArgs(1));
    await tester.pump();
    await sendBack(tester, 'commitBackGesture');
    await tester.pumpAndSettle();

    expect(find.text('page'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('M3EPageRoute：预测返回取消 / 提交途中主题重建不抛异常', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();

    Widget buildApp(ColorScheme scheme) {
      final material = buildAppThemeData(scheme);
      return M3EMaterialApp(
        data: M3EThemeData.fromMaterial(material),
        theme: material,
        darkTheme: material,
        autoTheming: false,
        dynamicColoring: false,
        themeAnimationStyle: AnimationStyle.noAnimation,
        navigatorKey: navigatorKey,
        home: M3ERouteTheme(
          builder: (_) => const Scaffold(body: Center(child: Text('home'))),
        ),
      );
    }

    await tester.pumpWidget(
      buildApp(ColorScheme.fromSeed(seedColor: seed)),
    );
    navigatorKey.currentState!.push(
      M3EPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('page'))),
      ),
    );
    await tester.pumpAndSettle();

    // 取消路径：退场动画进行中换主题（模拟封面取色 / 系统亮度），
    // App 级 DefaultTextStyle 会重建；页面已依赖路由级的那一层，不应断言。
    await sendBack(tester, 'startBackGesture', backArgs(0));
    await tester.pump();
    expect(navigatorKey.currentState!.userGestureInProgress, isTrue);
    await tester.pumpWidget(
      buildApp(
        ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
      ),
    );
    await tester.pump();
    await sendBack(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('page'), findsOneWidget);

    // 提交路径：同样在退场途中换主题，页面应正常出栈。
    await sendBack(tester, 'startBackGesture', backArgs(0));
    await tester.pump();
    await tester.pumpWidget(
      buildApp(ColorScheme.fromSeed(seedColor: seed)),
    );
    await tester.pump();
    await sendBack(tester, 'updateBackGestureProgress', backArgs(1));
    await tester.pump();
    await sendBack(tester, 'commitBackGesture');
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('page'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });
}
