/// 窗口宽度档位与壳层布局作用域。
///
/// 结构断点只在这里：compact < 600、medium 600–839、expanded ≥ 840。判据只有
/// 宽度，不看设备类型 / 桌面平台标记。壳层在 `build` 里解析一次并向下提供；
/// 页面、分栏与设置弹层只消费，不自己量窗口。
library;

import 'package:material_ui/material_ui.dart';

/// 窗口宽度档位（结构断点的唯一来源）。
enum WindowSizeClass { compact, medium, expanded }

/// 纯解析函数：窗口宽 → 档位。边界属于契约，改阈值只会改这里。
abstract final class WindowSizeClassResolver {
  static const double mediumMinWidth = 600;
  static const double expandedMinWidth = 840;

  static WindowSizeClass resolve(double width) {
    if (width < mediumMinWidth) return WindowSizeClass.compact;
    if (width < expandedMinWidth) return WindowSizeClass.medium;
    return WindowSizeClass.expanded;
  }
}

/// 收藏 / 曲库的合集分栏只在 expanded 启用（medium 保持单栏）。
bool collectionsUseSplitLayout(WindowSizeClass sizeClass) =>
    sizeClass == WindowSizeClass.expanded;

/// 播放页宽版式（封面/控制 + 队列/歌词/信息）只在 expanded 启用。
bool usesWideNowPlayingLayout(WindowSizeClass sizeClass) =>
    sizeClass == WindowSizeClass.expanded;

/// 解析结果（不可变值）：页面只读它，不需要 InheritedWidget 本身。
class AdaptiveLayout {
  const AdaptiveLayout({required this.sizeClass, required this.windowWidth});

  factory AdaptiveLayout.fromWidth(double width) => AdaptiveLayout(
    sizeClass: WindowSizeClassResolver.resolve(width),
    windowWidth: width,
  );

  final WindowSizeClass sizeClass;
  final double windowWidth;

  bool get isCompact => sizeClass == WindowSizeClass.compact;
  bool get isMedium => sizeClass == WindowSizeClass.medium;
  bool get isExpanded => sizeClass == WindowSizeClass.expanded;

  /// 结构导航：medium 起用导航轨；compact 用底栏。
  bool get usesNavigationRail => !isCompact;

  @override
  bool operator ==(Object other) =>
      other is AdaptiveLayout &&
      other.sizeClass == sizeClass &&
      other.windowWidth == windowWidth;

  @override
  int get hashCode => Object.hash(sizeClass, windowWidth);
}

/// 壳层解析一次的布局档位：页面 / 分栏 / 弹层只消费。
///
/// **作用域优先级**：
/// - 壳层（移动 / 桌面）用 [scope] 包住整个导航壳，页面读到的就是窗口档位；
/// - 页面型弹层 / 侧滑弹层用 [local] 包住内容，档位按**弹层自身约束宽**解析
///   （设置弹层被 880 上限夹住时不会误读整窗宽度）；
/// - 无作用域的独立路由 / 组件测试回退到窗口宽（MediaQuery），只用于兜底，
///   不伪造一个带空 child 的 InheritedWidget。
class AdaptiveLayoutScope extends InheritedWidget {
  const AdaptiveLayoutScope({
    super.key,
    required this.layout,
    required super.child,
  });

  final AdaptiveLayout layout;

  /// 壳层入口：按窗口宽解析并包住 [child]。
  static Widget scope(BuildContext context, {required Widget child}) {
    final width = MediaQuery.sizeOf(context).width;
    return AdaptiveLayoutScope(
      layout: AdaptiveLayout.fromWidth(width),
      child: child,
    );
  }

  /// 弹层 / 侧滑入口：按本层实际约束宽解析（有限宽度才用约束）。
  ///
  /// 设置弹层、页面型弹层与二级页正文都经这里包一层；这样「窗口 1200、
  /// 弹层 880」时页面读到的是 880 的档位，而不是窗口档位。
  static Widget local({required Widget child}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        return AdaptiveLayoutScope(
          layout: AdaptiveLayout.fromWidth(width),
          child: child,
        );
      },
    );
  }

  /// 消费入口：壳层 / 弹层作用域优先；独立挂载时按窗口宽兜底。
  static AdaptiveLayout of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AdaptiveLayoutScope>()
          ?.layout ??
      AdaptiveLayout.fromWidth(MediaQuery.sizeOf(context).width);

  @override
  bool updateShouldNotify(AdaptiveLayoutScope oldWidget) =>
      layout != oldWidget.layout;
}
