import 'package:material_ui/material_ui.dart';

/// 窗口宽度档位（结构断点的唯一来源）。
///
/// 只看宽度，不看设备类型 / 桌面平台标记：同一宽度在任何目标上得到同一档位。
/// - compact：< 600（手机、窄窗）
/// - medium：600–839（平板竖屏、折叠展开、窄桌面窗口）
/// - expanded：>= 840（平板横屏、折叠大屏、桌面）
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

/// 壳层解析一次的布局档位：页面 / 分栏 / 弹层只消费，不自己量宽。
///
/// 无壳层（独立挂载的页面、弹层路由、测试）时 [of] 按当前 MediaQuery 回退
/// 解析，公式与生产路径相同。
class AdaptiveLayoutScope extends InheritedWidget {
  const AdaptiveLayoutScope({
    super.key,
    required this.sizeClass,
    required this.windowWidth,
    required super.child,
  });

  final WindowSizeClass sizeClass;
  final double windowWidth;

  bool get isCompact => sizeClass == WindowSizeClass.compact;
  bool get isMedium => sizeClass == WindowSizeClass.medium;
  bool get isExpanded => sizeClass == WindowSizeClass.expanded;

  /// 结构导航：medium 起用导航轨；compact 用底栏。
  bool get usesNavigationRail => !isCompact;

  static AdaptiveLayoutScope scope(
    BuildContext context, {
    required Widget child,
  }) {
    final width = MediaQuery.sizeOf(context).width;
    return AdaptiveLayoutScope(
      sizeClass: WindowSizeClassResolver.resolve(width),
      windowWidth: width,
      child: child,
    );
  }

  static AdaptiveLayoutScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AdaptiveLayoutScope>() ??
      _fallback(context);

  static AdaptiveLayoutScope _fallback(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return AdaptiveLayoutScope(
      sizeClass: WindowSizeClassResolver.resolve(width),
      windowWidth: width,
      child: const SizedBox.shrink(),
    );
  }

  @override
  bool updateShouldNotify(AdaptiveLayoutScope oldWidget) =>
      sizeClass != oldWidget.sizeClass || windowWidth != oldWidget.windowWidth;
}
