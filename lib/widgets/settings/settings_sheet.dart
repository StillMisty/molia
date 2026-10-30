import 'dart:async';

import 'package:flutter/services.dart' show PredictiveBackEvent;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../pages/settings_page.dart';
import '../../utils/responsive.dart';
import '../desktop_layout.dart';

/// 打开设置弹层（顶栏入口与测试共用）。
///
/// 小屏（底部弹层）：
/// - 普通返回 / 下滑 / 遮罩点击走 dismiss guard：先在弹层内部退子页，子页
///   退完后再允许关闭（对齐 Compose `settleToDismiss` 的「收起一级」语义）。
/// - 预测返回按「手势归属」分叉：首屏手势由弹层宿主接管（跟手收缩，提交即
///   关闭）；子页手势由内层路由接管（跟手播放 FadeForwards 页面退场，提交只
///   退子页），此时弹层宿主的缩放置 0，不会出现「子页手势却是 sheet 收缩」。
///   归属由 [SettingsSheetBackCoordinator] 在每次手势开始时判定。
/// 大屏（M3E 页面弹窗）忽略 guard，返回由弹层壳的内层 Navigator 处理。
Future<void> showSettingsSheet(BuildContext context) {
  final navigatorKey = GlobalKey<NavigatorState>();
  final backCoordinator = SettingsSheetBackCoordinator();
  return ResponsiveNavigation.showPageModal<void>(
    context: context,
    // 宽屏设置弹层单独加宽（首屏两列）：公共 modal 档保持 560，避免定时
    // 关闭 / 来源分享 / AI 推歌这些窄弹层跟着摊宽。
    maxWidth: DesktopLayout.of(context).masterDetail
        ? kSettingsSheetDesktopWidth
        : null,
    sheetThemeBuilder: (base) => _SettingsSheetTheme(base, backCoordinator),
    onDismissRequest: () async {
      // 预测返回提交：由手势归属决定收谁。子页手势返回 false，内层路由
      // 自己 pop；若这里也 pop 会一次手势退两级。
      if (backCoordinator.predictiveBackActive) {
        return backCoordinator.sheetShrinksOnPredictiveBack;
      }
      // 普通返回 / 下滑 / 遮罩：先退子页，再允许关弹层。
      final navigator = navigatorKey.currentState;
      if (navigator != null && navigator.canPop()) {
        unawaited(navigator.maybePop());
        return false;
      }
      return true;
    },
    child: _SettingsSheetShell(
      navigatorKey: navigatorKey,
      backCoordinator: backCoordinator,
    ),
  );
}

/// 设置弹层预测返回的手势归属，也是这两个状态位的唯一所有者。
///
/// 为什么需要：框架把同一次手势派发给**所有**返回 true 的观察者，而
/// `Route.isCurrent` 只看自己那个 Navigator——弹层开着时，内层子页在它自己的
/// Navigator 里依然是 current。若不做归属判定，M3E 弹层宿主（负责 sheet 收缩）
/// 与内层子页（负责页面退场）会同时预览、提交时一次手势退两级。
///
/// 状态只在每次手势开始时由 [beginPredictiveBack] 固定：
/// - [sheetShrinksOnPredictiveBack]：子页手势为 false（弹层缩放归零，只显示
///   页面过渡）；首屏手势为 true（弹层正常收缩）。值保持到下一次手势开始，
///   避免子页 pop 后弹层缩放突然跳变。
/// - [predictiveBackActive]：内层路由真的接管了本次手势，dismiss guard 据此
///   让行；[endPredictiveBack] 在整轮提交/取消分发之后异步清除。
class SettingsSheetBackCoordinator {
  bool get predictiveBackActive => _predictiveBackActive;
  bool get sheetShrinksOnPredictiveBack => _sheetShrinksOnPredictiveBack;

  bool _predictiveBackActive = false;
  bool _sheetShrinksOnPredictiveBack = true;

  /// 预测返回手势开始：记录本次手势的归属。
  ///
  /// [canPopInnerRoute] 决定弹层是否跟手收缩；[handledByInnerRoute] 表示
  /// 内层路由接管了本次手势（由 detector 判定）。没接管时保持 active 原值，
  /// 避免同一次手势的多个观察者按注册顺序互相覆盖。
  void beginPredictiveBack({
    required bool canPopInnerRoute,
    bool handledByInnerRoute = false,
  }) {
    _sheetShrinksOnPredictiveBack = !canPopInnerRoute;
    if (handledByInnerRoute) {
      _predictiveBackActive = true;
    }
  }

  /// 内层路由已处理提交/取消。
  ///
  /// 重置必须排到整轮分发之后的微任务里：弹层宿主的 guard 与内层 detector
  /// 的观察者注册顺序不保证，同步清除会让 guard 读不到本次手势的归属。
  void endPredictiveBack() {
    scheduleMicrotask(() {
      _predictiveBackActive = false;
    });
  }
}

/// 设置弹层壳：内部 Navigator 承载首屏与子页（避免弹层叠弹层）。
///
/// 首屏内容由 [SettingsPage] 提供；本壳只负责路由栈、过渡主题与返回处理。
///
/// 返回处理按宿主形态分叉：
/// - 小屏（M3E 底部弹层）：普通返回走宿主 dismiss guard（见 `showSettingsSheet`）
///   「先退子页、再关弹层」；预测返回由 [_SettingsPageTransitionsBuilder] 按
///   手势归属分派——首屏归弹层宿主（收缩），子页归内层路由（页面过渡）。
///   本壳不挂 PopScope，避免同一次返回被两处处理。
/// - 大屏（居中对话框）：没有宿主 guard，由 [NavigatorPopHandler] 转发系统
///   返回——先退子页，回到首屏后对话框正常关闭。
class _SettingsSheetShell extends StatefulWidget {
  const _SettingsSheetShell({
    required this.navigatorKey,
    required this.backCoordinator,
  });

  /// 弹层宿主与 dismiss guard 共享的内部导航 key。
  final GlobalKey<NavigatorState> navigatorKey;

  /// 弹层预测返回的手势归属。
  final SettingsSheetBackCoordinator backCoordinator;

  @override
  State<_SettingsSheetShell> createState() => _SettingsSheetShellState();
}

class _SettingsSheetShellState extends State<_SettingsSheetShell> {
  /// 弹层宿主下发的滚动控制器：首屏滚动视图必须显式挂它，才能保留
  /// 「列表滚到顶继续下滑 = 收缩/关闭弹层」的联动。
  ///
  /// 为什么不能靠 PrimaryScrollController 自动继承：本壳内部还有一层
  /// Navigator，Flutter 的 ModalRoute 会给每条路由装一个自己的
  /// PrimaryScrollController，会把弹层的控制器遮蔽掉（弹层拖拽随之失效）。
  M3EBottomSheetScrollController? _sheetScrollController;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sheetScrollController = M3EBottomSheet.scrollControllerOf(context);
  }

  /// 内层 Navigator 的过渡主题：正常过渡保持 fade-forwards，Android 额外
  /// 插入按手势归属分派的预测返回 detector（见 [_SettingsPageTransitionsBuilder]）。
  ///
  /// 为什么不能直接用框架的 `PredictiveBackPageTransitionsBuilder`：它的
  /// detector 只看 `route.isCurrent`（内层 Navigator 自己的 current），根导航器
  /// 开着 dialog / 弹层时仍会接管手势，和上层表面抢同一次返回。这里把
  /// 「弹层路由是否仍是顶层」也纳入判定，并让首屏手势留给 M3E 弹层宿主。
  ThemeData _innerTransitionTheme(
    BuildContext context,
    ModalRoute<dynamic>? sheetRoute,
  ) {
    final base = Theme.of(context);
    return base.copyWith(
      pageTransitionsTheme: PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          ...base.pageTransitionsTheme.builders,
          TargetPlatform.android: _SettingsPageTransitionsBuilder(
            backCoordinator: widget.backCoordinator,
            navigatorKey: widget.navigatorKey,
            sheetRoute: sheetRoute,
          ),
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 依赖弹层路由的 isCurrent：根导航器上再压 dialog 时，内层子页必须让出
    // 预测返回（否则会退子页而 dialog 留下）。
    final sheetRoute = ModalRoute.of(context);
    final navigator = Navigator(
      key: widget.navigatorKey,
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => SettingsPage(scrollController: _sheetScrollController),
      ),
    );
    final themed = Theme(
      data: _innerTransitionTheme(context, sheetRoute),
      child: navigator,
    );
    if (!context.isLargeScreen) {
      return themed;
    }
    return NavigatorPopHandler(
      onPopWithResult: (_) => widget.navigatorKey.currentState?.maybePop(),
      child: themed,
    );
  }
}

/// 内层路由的 Android 过渡：fade-forwards + 按归属分派的预测返回。
class _SettingsPageTransitionsBuilder extends PageTransitionsBuilder {
  const _SettingsPageTransitionsBuilder({
    required this.backCoordinator,
    required this.navigatorKey,
    required this.sheetRoute,
  });

  final SettingsSheetBackCoordinator backCoordinator;
  final GlobalKey<NavigatorState> navigatorKey;

  /// 承载设置内容的弹层/对话框路由；根导航器上再压表面时 isCurrent 为 false。
  final ModalRoute<dynamic>? sheetRoute;

  @override
  Duration get transitionDuration =>
      const FadeForwardsPageTransitionsBuilder().transitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _SettingsPredictiveBackDetector(
      route: route,
      backCoordinator: backCoordinator,
      navigatorKey: navigatorKey,
      sheetRoute: sheetRoute,
      child: FadeForwardsPageTransitionsBuilder().buildTransitions<T>(
        route,
        context,
        animation,
        secondaryAnimation,
        child,
      ),
    );
  }
}

/// 只服务设置内层路由的预测返回 detector。
///
/// 与框架 `PredictiveBackPageTransitionsBuilder` 的 detector 同构，但多两道闸：
/// 1. 内层 Navigator 必须真的能 pop（首屏手势留给 M3E 弹层宿主做 sheet 收缩）；
/// 2. 弹层/对话框路由必须仍是顶层（根导航器上再压 dialog 时让给 dialog）。
class _SettingsPredictiveBackDetector extends StatefulWidget {
  const _SettingsPredictiveBackDetector({
    required this.route,
    required this.backCoordinator,
    required this.navigatorKey,
    required this.sheetRoute,
    required this.child,
  });

  final PageRoute<dynamic> route;
  final SettingsSheetBackCoordinator backCoordinator;
  final GlobalKey<NavigatorState> navigatorKey;
  final ModalRoute<dynamic>? sheetRoute;
  final Widget child;

  @override
  State<_SettingsPredictiveBackDetector> createState() =>
      _SettingsPredictiveBackDetectorState();
}

class _SettingsPredictiveBackDetectorState
    extends State<_SettingsPredictiveBackDetector>
    with WidgetsBindingObserver {
  bool _handling = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    final canPop = widget.navigatorKey.currentState?.canPop() ?? false;
    final takesGesture =
        !backEvent.isButtonEvent &&
        widget.route.isCurrent &&
        widget.route.popGestureEnabled &&
        canPop &&
        (widget.sheetRoute?.isCurrent ?? true);
    // 每次手势开始时固定归属：子页手势期间弹层缩放为 0；首屏手势保留原收缩。
    // 值保持到下一次手势开始，避免子页 pop 后弹层缩放突然出现。
    widget.backCoordinator.beginPredictiveBack(
      canPopInnerRoute: canPop,
      handledByInnerRoute: takesGesture,
    );

    if (!takesGesture) {
      return false;
    }

    _handling = true;
    widget.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_handling) return;
    widget.route.handleUpdateBackGestureProgress(
      progress: 1 - backEvent.progress,
    );
  }

  @override
  void handleCommitBackGesture() {
    if (!_handling) return;
    _handling = false;
    widget.route.handleCommitBackGesture();
    widget.backCoordinator.endPredictiveBack();
  }

  @override
  void handleCancelBackGesture() {
    if (!_handling) return;
    _handling = false;
    widget.route.handleCancelBackGesture();
    widget.backCoordinator.endPredictiveBack();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 动态调整弹层预测缩放：子页手势时宿主仍收到手势，但视觉上不缩放，
/// 只展示内层路由的页面过渡；首屏手势恢复 M3E 的原生 sheet 收缩。
class _SettingsSheetTheme extends M3EBottomSheetTheme {
  _SettingsSheetTheme(M3EBottomSheetTheme base, this._backCoordinator)
    : super(
        maxWidth: base.maxWidth,
        topCornerRadius: base.topCornerRadius,
        handleWidth: base.handleWidth,
        handleHeight: base.handleHeight,
        handleCornerRadius: base.handleCornerRadius,
        handleVerticalPadding: base.handleVerticalPadding,
        handleOpacity: base.handleOpacity,
        scrimOpacity: base.scrimOpacity,
        dismissVelocity: base.dismissVelocity,
        wideBreakpoint: base.wideBreakpoint,
        compactTopMargin: base.compactTopMargin,
        wideTopMargin: base.wideTopMargin,
        wideSideMargin: base.wideSideMargin,
        bottomCornerRadius: base.bottomCornerRadius,
        modalElevation: base.modalElevation,
        standardElevation: base.standardElevation,
        initialHeightFraction: base.initialHeightFraction,
        dismissThresholdFraction: base.dismissThresholdFraction,
        handleCyclesToClose: base.handleCyclesToClose,
        fullScreenHeaderHeight: base.fullScreenHeaderHeight,
        enterSpring: base.enterSpring,
        settleSpring: base.settleSpring,
        layoutSpring: base.layoutSpring,
        scrimSpring: base.scrimSpring,
        predictiveBackShrinkX: base.predictiveBackShrinkX,
        predictiveBackShrinkY: base.predictiveBackShrinkY,
        adaptiveSideSheetBreakpoint: base.adaptiveSideSheetBreakpoint,
        colors: base.colors,
        dragHandle: base.dragHandle,
      );

  final SettingsSheetBackCoordinator _backCoordinator;

  @override
  double get predictiveBackShrinkX =>
      _backCoordinator.sheetShrinksOnPredictiveBack
      ? super.predictiveBackShrinkX
      : 0;

  @override
  double get predictiveBackShrinkY =>
      _backCoordinator.sheetShrinksOnPredictiveBack
      ? super.predictiveBackShrinkY
      : 0;
}
