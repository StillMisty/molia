import 'package:flutter/widgets.dart';

/// 响应式设计断点常量
/// 用于在整个应用中统一响应式行为
abstract class Breakpoints {
  /// 极窄设备 (小型手机，如 iPhone SE)
  static const double compact = 350;

  /// 标准手机宽度
  static const double mobile = 400;

  /// 平板/大屏幕手机
  static const double tablet = 600;

  /// 桌面/超宽屏幕
  static const double desktop = 900;
}

/// 设备类型枚举
enum DeviceType { compact, mobile, tablet, desktop }

/// 宽度 → 设备类型（[Breakpoints] 的唯一换算入口）。
DeviceType deviceTypeForWidth(double width) {
  if (width < Breakpoints.compact) return DeviceType.compact;
  if (width < Breakpoints.tablet) return DeviceType.mobile;
  if (width < Breakpoints.desktop) return DeviceType.tablet;
  return DeviceType.desktop;
}

/// 视口粗档作用域：只在 [DeviceType] 变化时通知。
///
/// 桌面拖拽窗口时窗口宽每个像素都在变，但 `layoutType` /
/// `horizontalPadding` / `isLargeScreen` 这类结构判据只可能取四档值。直接读
/// `MediaQuery.sizeOf` 会让页面（收藏正文、表格行）跟着逐像素重建；这层把
/// 订阅收窄到档位。需要连续宽度的叶子用 `LayoutBuilder` 读约束。
class ViewportClassScope extends InheritedWidget {
  const ViewportClassScope({
    super.key,
    required this.deviceType,
    required super.child,
  });

  final DeviceType deviceType;

  /// 消费入口；无宿主（独立挂载 / 组件测试）时返回 null，由调用方按宽回退。
  static DeviceType? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ViewportClassScope>()
      ?.deviceType;

  /// 宿主入口：读取窗口宽并包住 [child]，只在档位翻转时通知。
  static Widget host({required Widget child}) =>
      _ViewportClassHost(child: child);

  @override
  bool updateShouldNotify(ViewportClassScope oldWidget) =>
      deviceType != oldWidget.deviceType;
}

class _ViewportClassHost extends StatelessWidget {
  const _ViewportClassHost({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ViewportClassScope(
    deviceType: deviceTypeForWidth(MediaQuery.sizeOf(context).width),
    child: child,
  );
}
