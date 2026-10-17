import 'package:material_ui/material_ui.dart';

import '../utils/responsive.dart';
import 'track_row.dart';

/// 按当前 context 解析桌面布局（[DesktopLayout.of] 的回退与壳层提供共用）。
///
/// 为什么放在类外：类里有一个同名的 `isDesktopPlatform` 字段，类作用域会
/// 遮蔽 `responsive.dart` 的同名判定函数，类内静态方法调不到它。
DesktopLayout _resolveLayout(BuildContext context, {Widget? child}) =>
    DesktopLayout(
      isDesktopPlatform: isDesktopPlatform(),
      windowWidth: MediaQuery.sizeOf(context).width,
      child: child ?? const SizedBox.shrink(),
    );

/// 桌面布局解析结果：壳层一次解析，页面 / 骨架只消费。
///
/// 为什么集中：同一句「是不是桌面宽布局」若分散在收藏页 / 设置页 / 资料库 /
/// 表格列 / 桌面骨架里各自推导，阈值与宽度来源（屏幕宽 / 内容宽 / 窗口宽）
/// 的漂移没有任何机制能发现。本类把两类语义分开表达：
///
/// - 窗口宽语义是字段（[masterDetail] / [searchCompact] /
///   [railForceCollapsed] / [queuePanelAvailable]）：壳层在 `build` 里解析
///   一次并向下提供；
/// - 内容宽语义是 `*At(contentWidth)` 方法：内容区宽度只有渲染期才知道
///   （桌面侧栏 / 队列面板 / 页内合集栏都会吃掉宽度），由消费方量出后传入，
///   但「用内容宽 + 哪个阈值 + 平台判据」只此一处。
///
/// 无壳层（独立挂载页面 / 弹层路由 / 测试）时 [of] 按当前 context 回退解析，
/// 与壳层生产路径同一公式。
class DesktopLayout extends InheritedWidget {
  const DesktopLayout({
    super.key,
    required this.isDesktopPlatform,
    required this.windowWidth,
    required super.child,
  });

  /// 当前平台是否桌面（linux / windows / macOS）：桌面增强的总开关。
  ///
  /// 与壳层骨架分流同源（`defaultTargetPlatform`），测试里可经
  /// `MyApp(desktopShell:)` 强制骨架，但页面内的桌面增强仍按平台判定——
  /// 它们只在桌面骨架里渲染，无需再逐层传开关。
  final bool isDesktopPlatform;

  /// 解析时的窗口宽（屏幕宽语义）。
  final double windowWidth;

  /// 页面级桌面增强（窗口宽语义）：桌面平台 + 窗口宽 ≥ [Breakpoints.desktop]。
  ///
  /// 消费方：收藏页 master-detail 合集栏与设置首屏两列——同一判据合并为一处，
  /// 两页观感不会再各自漂移。
  bool get masterDetail =>
      isDesktopPlatform && windowWidth >= Breakpoints.desktop;

  /// 顶栏搜索形态：窗口宽 < [Breakpoints.desktop]（900）退化为图标按钮。
  ///
  /// 消费方：桌面骨架顶栏与壳层 Ctrl+F 快捷键分流（两者必须同一判据，
  /// 否则快捷键会落到不可见的入口上）。
  bool get searchCompact => windowWidth < Breakpoints.desktop;

  /// 桌面侧栏是否强制折叠（窗口宽 < [railForceCollapseWidth]）。
  ///
  /// 只影响渲染，不改布局记忆值：变宽后按用户设定恢复。
  bool get railForceCollapsed => windowWidth < railForceCollapseWidth;

  /// 队列面板是否可渲染（窗口宽 ≥ [queueForceCloseWidth]）。
  bool get queuePanelAvailable => windowWidth >= queueForceCloseWidth;

  /// 宽屏表格列（内容宽语义）：桌面平台 + 内容宽 ≥
  /// [TrackRowColumns.minWidth]。
  ///
  /// 为什么按内容宽：桌面骨架的侧栏与队列面板会吃掉窗口宽度，同样 1200 的
  /// 窗口内容区可能只剩 600——按窗口宽判定会给出固定列宽的行、把行撑溢出。
  bool tableColumnsAt(double contentWidth) =>
      isDesktopPlatform && contentWidth >= TrackRowColumns.minWidth;

  /// 资料库渠道竖栏（内容宽语义）：桌面平台 + 内容宽 ≥ [Breakpoints.desktop]。
  ///
  /// 与 [tableColumnsAt] 同一宽度来源：渠道入口与搜索结果表格列共处同一内容
  /// 区，口径必须同源；渠道数量等页面自身条件由调用方 AND。
  bool channelRailAt(double contentWidth) =>
      isDesktopPlatform && contentWidth >= Breakpoints.desktop;

  /// 侧栏强制折叠阈值（桌面骨架专用）。
  static const double railForceCollapseWidth = 1000;

  /// 队列面板可渲染阈值（桌面骨架专用；<1200 时面板不渲染、入口置灰）。
  static const double queueForceCloseWidth = 1200;

  /// 壳层提供入口：解析当前 context 的窗口宽 / 平台位，并用结果包住 [child]。
  static Widget scope(BuildContext context, {required Widget child}) =>
      _resolveLayout(context, child: child);

  /// 解析当前 context 的桌面布局（壳层非 build 时读取：快捷键分流等）。
  static DesktopLayout resolve(BuildContext context) => _resolveLayout(context);

  /// 消费入口：取壳层解析结果；无壳层时按当前 context 回退解析。
  static DesktopLayout of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopLayout>() ??
      _resolveLayout(context);

  @override
  bool updateShouldNotify(DesktopLayout oldWidget) =>
      isDesktopPlatform != oldWidget.isDesktopPlatform ||
      windowWidth != oldWidget.windowWidth;
}
