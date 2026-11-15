/// 窗口尺寸档位与壳层布局作用域。
///
/// 结构档位仍只由宽度决定：compact < 600、medium 600–839、expanded ≥ 840，
/// 不看设备类型 / 桌面平台标记。高度只额外给出一个「短横屏」布尔
/// （[AdaptiveLayout.isShortViewport]），用于纵向预算不足时切换播放页版式；
/// 不建立第二套宽度档，也不让页面自己量窗口。壳层在 `build` 里解析一次
/// 并向下提供；页面、分栏与设置弹层只消费。
library;

import 'package:material_ui/material_ui.dart';

/// 窗口宽度档位（结构断点的唯一来源）。
enum WindowSizeClass { compact, medium, expanded }

/// 纯解析函数：窗口尺寸 → 档位 / 短横屏判定。边界属于契约，改阈值只会改这里。
abstract final class WindowSizeClassResolver {
  static const double mediumMinWidth = 600;
  static const double expandedMinWidth = 840;

  /// 短横屏高度上限：手机横屏最高约 430（大屏 iPhone），平板横屏通常
  /// ≥600，桌面最小窗口 480×400 也落在此档。低于它说明纵向预算不足以
  /// 维持单栏播放页的「封面 + 标题 + 进度 + 内容」，改走左右两栏。
  static const double shortViewportMaxHeight = 480;

  static WindowSizeClass resolve(double width) {
    if (width < mediumMinWidth) return WindowSizeClass.compact;
    if (width < expandedMinWidth) return WindowSizeClass.medium;
    return WindowSizeClass.expanded;
  }

  /// 窗口高是否不足以沿用纵向版式。
  static bool isShortViewport(double height) => height < shortViewportMaxHeight;
}

/// 曲库专辑 / 歌手浏览的左右分栏只在 expanded 启用（medium 保持单栏）。
bool libraryBrowseUsesSplitLayout(WindowSizeClass sizeClass) =>
    sizeClass == WindowSizeClass.expanded;

/// 播放页宽版式（封面/控制 + 队列/歌词/信息）的启用判据。
///
/// 除了 expanded 档，medium 的短横屏（手机横屏 600–839 宽）也走两栏：
/// 单栏在这个高度下歌词 / 队列只剩一行多，宁可把宽度对半分给左右两栏。
/// compact 仍保持单栏（最窄的横屏手机 / 480×400 桌面窗口放不下两栏）。
bool usesWideNowPlayingLayout(AdaptiveLayout layout) =>
    layout.sizeClass == WindowSizeClass.expanded ||
    (layout.isShortViewport && !layout.isCompact);

/// 解析结果（不可变值）：页面只读它，不需要 InheritedWidget 本身。
class AdaptiveLayout {
  const AdaptiveLayout({
    required this.sizeClass,
    required this.windowWidth,
    required this.windowHeight,
  });

  factory AdaptiveLayout.fromSize(double width, double height) =>
      AdaptiveLayout(
        sizeClass: WindowSizeClassResolver.resolve(width),
        windowWidth: width,
        windowHeight: height,
      );

  final WindowSizeClass sizeClass;

  /// 解析时的窗口宽（屏幕宽语义，不减安全区 / 导航栏）。
  final double windowWidth;

  /// 解析时的窗口高（屏幕高语义；弹层作用域里是本层约束高）。
  final double windowHeight;

  bool get isCompact => sizeClass == WindowSizeClass.compact;
  bool get isMedium => sizeClass == WindowSizeClass.medium;
  bool get isExpanded => sizeClass == WindowSizeClass.expanded;

  /// 窗口高 < 480：手机横屏 / 极矮窗口。结构档位不受它影响。
  bool get isShortViewport =>
      WindowSizeClassResolver.isShortViewport(windowHeight);

  /// 结构导航：medium 起用导航轨；compact 用底栏。
  bool get usesNavigationRail => !isCompact;

  @override
  bool operator ==(Object other) =>
      other is AdaptiveLayout &&
      other.sizeClass == sizeClass &&
      other.windowWidth == windowWidth &&
      other.windowHeight == windowHeight;

  @override
  int get hashCode => Object.hash(sizeClass, windowWidth, windowHeight);
}

/// 壳层解析一次的布局档位：页面 / 分栏 / 弹层只消费。
///
/// **作用域优先级**：
/// - 壳层（移动 / 桌面）用 [scope] 包住整个导航壳，页面读到的就是窗口尺寸；
/// - 页面型弹层 / 侧滑弹层用 [local] 包住内容，档位按**弹层自身约束**解析
///   （设置弹层被 880 上限夹住时不会误读整窗宽度；高度同理，短弹层不会被
///   当成整窗高度）；
/// - 无作用域的独立路由 / 组件测试回退到窗口尺寸（MediaQuery），只用于兜底，
///   不伪造一个带空 child 的 InheritedWidget。
class AdaptiveLayoutScope extends InheritedWidget {
  const AdaptiveLayoutScope({
    super.key,
    required this.layout,
    required super.child,
  });

  final AdaptiveLayout layout;

  /// 壳层入口：按窗口尺寸解析并包住 [child]。
  static Widget scope(BuildContext context, {required Widget child}) {
    final size = MediaQuery.sizeOf(context);
    return AdaptiveLayoutScope(
      layout: AdaptiveLayout.fromSize(size.width, size.height),
      child: child,
    );
  }

  /// 弹层 / 侧滑入口：按本层实际约束解析（有限宽高才用约束）。
  ///
  /// 设置弹层、页面型弹层与二级页正文都经这里包一层；这样「窗口 1200、
  /// 弹层 880」时页面读到的是 880 的档位，而不是窗口档位。高度也按弹层
  /// 自身给：横屏窗口里的短对话框不会被误判为整窗高度。
  static Widget local({required Widget child}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final media = MediaQuery.sizeOf(context);
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : media.width;
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : media.height;
        return AdaptiveLayoutScope(
          layout: AdaptiveLayout.fromSize(width, height),
          child: child,
        );
      },
    );
  }

  /// 消费入口：壳层 / 弹层作用域优先；独立挂载时按窗口尺寸兜底。
  static AdaptiveLayout of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdaptiveLayoutScope>();
    if (scope != null) return scope.layout;
    final size = MediaQuery.sizeOf(context);
    return AdaptiveLayout.fromSize(size.width, size.height);
  }

  @override
  bool updateShouldNotify(AdaptiveLayoutScope oldWidget) =>
      layout != oldWidget.layout;
}
