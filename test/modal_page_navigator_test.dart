import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/theme/app_theme.dart';
import 'package:molia/widgets/m3e_page_route.dart';
import 'package:molia/widgets/modal_page_navigator.dart';

void main() {
  group('ModalNavigatorBackCoordinator', () {
    test('默认：弹层保持收缩，预测返回未激活', () {
      final coordinator = ModalNavigatorBackCoordinator();

      expect(coordinator.sheetShrinksOnPredictiveBack, isTrue);
      expect(coordinator.predictiveBackActive, isFalse);
    });

    test('子页手势：弹层不收缩，接管后激活', () {
      final coordinator = ModalNavigatorBackCoordinator();

      coordinator.beginPredictiveBack(
        canPopInnerRoute: true,
        handledByInnerRoute: true,
      );

      expect(coordinator.sheetShrinksOnPredictiveBack, isFalse);
      expect(coordinator.predictiveBackActive, isTrue);
    });

    test('首屏手势：弹层收缩，不由内层路由接管', () {
      final coordinator = ModalNavigatorBackCoordinator();

      coordinator.beginPredictiveBack(canPopInnerRoute: false);

      expect(coordinator.sheetShrinksOnPredictiveBack, isTrue);
      expect(coordinator.predictiveBackActive, isFalse);
    });

    test('弹层上方还有表面：缩放归零但内层不接管（active 保持 false）', () {
      final coordinator = ModalNavigatorBackCoordinator();

      coordinator.beginPredictiveBack(canPopInnerRoute: true);

      expect(
        coordinator.sheetShrinksOnPredictiveBack,
        isFalse,
        reason: '内层能 pop 时缩放归属仍是子页，避免上层表面手势带出 sheet 收缩',
      );
      expect(coordinator.predictiveBackActive, isFalse);
    });

    test('end 在整轮分发后才重置 active，收缩归属保留到下一次手势', () {
      fakeAsync((async) {
        final coordinator = ModalNavigatorBackCoordinator();
        coordinator.beginPredictiveBack(
          canPopInnerRoute: true,
          handledByInnerRoute: true,
        );

        coordinator.endPredictiveBack();

        expect(
          coordinator.predictiveBackActive,
          isTrue,
          reason: '提交期间 observer 注册顺序不保证，guard 仍需读到本次归属',
        );
        expect(coordinator.sheetShrinksOnPredictiveBack, isFalse);

        async.flushMicrotasks();

        expect(coordinator.predictiveBackActive, isFalse);
        expect(
          coordinator.sheetShrinksOnPredictiveBack,
          isFalse,
          reason: '子页 pop 后弹层不得突然跳回收缩态',
        );
      });
    });

    test('下一次首屏手势重新固定收缩归属', () {
      fakeAsync((async) {
        final coordinator = ModalNavigatorBackCoordinator();
        coordinator.beginPredictiveBack(
          canPopInnerRoute: true,
          handledByInnerRoute: true,
        );
        coordinator.endPredictiveBack();
        async.flushMicrotasks();

        coordinator.beginPredictiveBack(canPopInnerRoute: false);

        expect(coordinator.sheetShrinksOnPredictiveBack, isTrue);
        expect(coordinator.predictiveBackActive, isFalse);
      });
    });
  });

  testWidgets('弹层内子页：预测返回驱动内层路由，提交只退一级', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final theme = buildAppThemeData(
      ColorScheme.fromSeed(seedColor: const Color(0xFF2196F3)),
    );
    final rootNavigator = GlobalKey<NavigatorState>();
    final innerNavigator = GlobalKey<NavigatorState>();
    final coordinator = ModalNavigatorBackCoordinator();
    late ModalRoute<dynamic> subPageRoute;

    await tester.pumpWidget(
      M3EMaterialApp(
        data: buildM3EThemeData(theme),
        theme: theme,
        darkTheme: theme,
        navigatorKey: rootNavigator,
        home: const Scaffold(body: Text('home')),
      ),
    );

    rootNavigator.currentState!.push(
      _TestSheetRoute(
        child: ModalPageNavigatorShell(
          navigatorKey: innerNavigator,
          backCoordinator: coordinator,
          initialPageBuilder: (context, _) => const Text('sheet first'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    innerNavigator.currentState!.push(
      M3EPageRoute<void>(
        builder: (context) {
          subPageRoute = ModalRoute.of(context)!;
          return const Text('sheet second');
        },
      ),
    );
    await tester.pumpAndSettle();

    await _sendBackGesture(tester, 'startBackGesture', const <String, dynamic>{
      'touchOffset': <double>[5.0, 300.0],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    expect(innerNavigator.currentState!.userGestureInProgress, isTrue);
    expect(coordinator.predictiveBackActive, isTrue);

    await _sendBackGesture(
      tester,
      'updateBackGestureProgress',
      const <String, dynamic>{
        'x': 100.0,
        'y': 300.0,
        'progress': 0.35,
        'swipeEdge': 0,
      },
    );
    expect(subPageRoute.animation!.value, closeTo(0.65, 0.001));

    await _sendBackGesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();

    expect(find.text('sheet second'), findsNothing);
    expect(find.text('sheet first'), findsOneWidget);
    expect(rootNavigator.currentState!.canPop(), isTrue, reason: '弹层本身保留');
  });
}

Future<void> _sendBackGesture(
  WidgetTester tester,
  String method, [
  Map<String, dynamic>? arguments,
]) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
    (_) {},
  );
  await tester.pump();
}

/// 模拟 M3E 弹层路由：不是 PageRoute，因此不会插入框架自带的预测返回
/// detector；内层 Navigator 的手势归属由 [ModalPageNavigatorTransitionsBuilder]
/// 单独判定。
class _TestSheetRoute extends PopupRoute<void> {
  _TestSheetRoute({required this.child});

  final Widget child;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => child;
}
